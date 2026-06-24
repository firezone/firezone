defmodule PortalWeb.OIDCController do
  use PortalWeb, :controller

  alias Portal.AuthProvider

  alias __MODULE__.Database

  alias PortalWeb.Cookie
  alias PortalWeb.OIDC.IdentityProfile
  alias PortalWeb.Session.Redirector

  require Logger

  @invalid_json_error_message "Discovery document contains invalid JSON. Please verify the Discovery Document URI returns valid OpenID Connect configuration."
  @unverified_email_error "Your identity provider did not return email_verified=true for your account. Please verify your email with the identity provider or contact your administrator."
  @constant_execution_time Application.compile_env(:portal, :constant_execution_time, 3000)

  @spec sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    account = Database.get_account_by_id_or_slug!(account_id_or_slug)
    provider = get_provider!(account, params)
    provider_redirect(conn, account, provider, params)
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"state" => state, "code" => code}) do
    case parse_callback_state(state) do
      {:oidc_verification, lv_pid_string} ->
        handle_oidc_verification(conn, code, lv_pid_string)

      _ ->
        handle_authentication_callback(conn, state, code)
    end
  end

  # Handle Entra admin consent callback (returns admin_consent and may include tenant)
  def callback(conn, %{"state" => state, "admin_consent" => _} = params) do
    case parse_callback_state(state) do
      {:entra_auth_provider, _lv_pid_string} ->
        redirect(conn, to: ~p"/verification/entra?#{params}")

      {:entra_directory_sync, _lv_pid_string} ->
        redirect(conn, to: ~p"/verification/entra?#{params}")

      _ ->
        handle_error(conn, {:error, :invalid_callback_params})
    end
  end

  def callback(conn, params) do
    Logger.info("OIDC callback called with invalid params", params: Map.keys(params))

    handle_error(conn, {:error, :invalid_callback_params})
  end

  @spec verify_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify_identity(conn, %{"secret" => entered_code} = params) do
    result =
      Portal.Timing.execute_with_constant_time(
        fn -> do_verify_identity(conn, params, String.downcase(entered_code)) end,
        @constant_execution_time
      )

    handle_verify_identity_result(conn, result, params)
  end

  def verify_identity(conn, params) do
    Logger.info("Invalid OIDC pending identity verification parameters", params: params)
    handle_error(conn, {:error, :invalid_callback_params})
  end

  defp handle_authentication_callback(conn, state, code) do
    case load_auth_context(conn, state) do
      {:ok, auth_context} ->
        run_authentication_flow(auth_context, code)

      error ->
        handle_error(conn, error)
    end
  end

  defp load_auth_context(conn, state) do
    with %Cookie.AuthenticationState{} = cookie <- Cookie.AuthenticationState.fetch(conn),
         :ok <- verify_state(cookie.state, state) do
      conn = Cookie.AuthenticationState.delete(conn)
      conn = put_oidc_error_context(conn, cookie)
      params = cookie.params || %{}
      context_type = context_type(params)
      account = Database.get_account_by_id_or_slug!(cookie.account_id)
      provider = get_provider!(account, cookie)

      {:ok,
       %{
         conn: conn,
         params: params,
         verifier: cookie.verifier,
         context_type: context_type,
         account: account,
         provider: provider
       }}
    else
      nil -> {:error, :oidc_state_not_found}
      {:error, :state_mismatch} -> {:error, :oidc_state_session_mismatch}
    end
  end

  defp verify_state(cookie_state, callback_state)
       when is_binary(cookie_state) and is_binary(callback_state) do
    if Plug.Crypto.secure_compare(cookie_state, callback_state) do
      :ok
    else
      {:error, :state_mismatch}
    end
  end

  defp verify_state(_cookie_state, _callback_state), do: {:error, :state_mismatch}

  defp run_authentication_flow(auth_context, code) do
    %{
      conn: conn,
      verifier: verifier,
      context_type: context_type,
      account: account,
      provider: provider
    } = auth_context

    with :ok <- validate_context(provider, context_type),
         :ok <- ensure_client_sign_in_allowed(account, context_type),
         {:ok, tokens} <- PortalWeb.OIDC.exchange_code(provider, code, verifier),
         {:ok, claims} <- PortalWeb.OIDC.verify_token(provider, tokens["id_token"]),
         userinfo = fetch_userinfo(provider, tokens["access_token"]),
         {:ok, identity_result} <- resolve_identity(account, provider, claims, userinfo) do
      finish_resolved_identity(auth_context, identity_result, tokens)
    else
      error -> handle_error(conn, error)
    end
  end

  defp finish_resolved_identity(
         %{
           conn: conn,
           context_type: context_type,
           account: account,
           provider: provider,
           params: params
         },
         {:identity, identity},
         tokens
       ) do
    with :ok <- check_admin(identity, context_type),
         {:ok, session_or_token} <-
           create_session_or_token(conn, identity, provider, params) do
      signed_in(conn, context_type, account, identity, session_or_token, provider, tokens, params)
    else
      error -> handle_error(conn, error)
    end
  end

  defp finish_resolved_identity(
         %{
           conn: conn,
           context_type: context_type,
           account: account,
           provider: provider,
           params: params
         },
         {:proof_required, actor, identity_profile},
         _tokens
       ) do
    with :ok <- check_actor(actor, context_type),
         {:ok, conn} <-
           start_owner_verification(conn, account, provider, actor, identity_profile, params) do
      conn
    else
      error -> handle_error(conn, error)
    end
  end

  defp provider_redirect(conn, account, provider, params) do
    opts = authorization_opts(provider)

    case PortalWeb.OIDC.authorization_uri(provider, opts) do
      {:ok, uri, state, verifier} ->
        cookie = %Cookie.AuthenticationState{
          auth_provider_type: params["auth_provider_type"],
          auth_provider_id: params["auth_provider_id"],
          account_id: account.id,
          account_slug: account.slug,
          state: state,
          verifier: verifier,
          params: sanitize(params)
        }

        conn
        |> Cookie.AuthenticationState.put(cookie)
        |> redirect(external: uri)

      {:error, reason} ->
        handle_authorization_uri_error(conn, account, provider, params, reason)
    end
  end

  defp handle_authorization_uri_error(conn, account, provider, params, reason) do
    Logger.warning("OIDC authorization URI error",
      account_id: account.id,
      provider_id: provider.id,
      reason: authorization_error_reason(reason)
    )

    error = authorization_error_message(reason)
    log_sign_in_redirect_error(account.id, error)
    path = error_path_for_context(account, params, error)

    conn
    |> put_flash(:error, error)
    |> redirect(to: path)
  end

  defp authorization_error_reason(%Req.TransportError{reason: reason}), do: inspect(reason)
  defp authorization_error_reason({status, _body}) when is_integer(status), do: "HTTP #{status}"
  defp authorization_error_reason(reason), do: inspect(reason)

  defp authorization_error_message(%Req.TransportError{reason: reason}),
    do: transport_error_message(reason)

  defp authorization_error_message({status, _body}) when is_integer(status),
    do: discovery_http_error_message(status)

  defp authorization_error_message(reason), do: discovery_error_message(reason)

  defp authorization_opts(provider) do
    if provider.__struct__ in [
         Portal.Google.AuthProvider,
         Portal.Entra.AuthProvider,
         Portal.Okta.AuthProvider
       ] do
      [additional_params: %{prompt: "select_account"}]
    else
      []
    end
  end

  defp transport_error_message(:nxdomain),
    do:
      "Unable to fetch discovery document: DNS lookup failed. Please verify the Discovery Document URI domain is correct."

  defp transport_error_message(:econnrefused),
    do:
      "Unable to fetch discovery document: Connection refused. The identity provider may be down."

  defp transport_error_message(:timeout),
    do: "Unable to fetch discovery document: Connection timed out. Please try again."

  defp transport_error_message(_reason),
    do: "Unable to fetch discovery document. Please check the Discovery Document URI."

  defp discovery_http_error_message(404),
    do:
      "Discovery document not found (HTTP 404). Please verify the Discovery Document URI is correct."

  defp discovery_http_error_message(status) when status in 500..599,
    do: "Identity provider returned a server error (HTTP #{status}). Please try again later."

  defp discovery_http_error_message(status),
    do:
      "Failed to fetch discovery document (HTTP #{status}). Please verify your provider configuration."

  defp discovery_error_message(:invalid_discovery_document_uri),
    do: "The Discovery Document URI is invalid. Please check your provider configuration."

  defp discovery_error_message(:private_ip_blocked),
    do: "The Discovery Document URI must not point to a private or reserved IP address."

  defp discovery_error_message(reason) do
    if invalid_json_reason?(reason) do
      @invalid_json_error_message
    else
      "Unable to connect to the identity provider. Please try again or contact your administrator."
    end
  end

  defp get_provider!(account, %{"auth_provider_type" => type, "auth_provider_id" => id}) do
    Database.get_provider!(account.id, type, id)
  end

  defp get_provider!(account, %{auth_provider_type: type, auth_provider_id: id}) do
    Database.get_provider!(account.id, type, id)
  end

  defp fetch_userinfo(provider, access_token) do
    case PortalWeb.OIDC.fetch_userinfo(provider, access_token) do
      {:ok, userinfo} -> userinfo
      _ -> %{}
    end
  end

  defp resolve_identity(account, provider, claims, userinfo) do
    email_claim = Map.get(provider, :email_claim)

    with {:ok, identity_profile} <-
           IdentityProfile.build(claims, userinfo, account.id, email_claim: email_claim) do
      resolve_identity(account, provider, identity_profile)
    end
  end

  defp resolve_identity(account, provider, identity_profile) do
    case email_verification_method(provider) do
      :none -> upsert_verified_identity(account, identity_profile)
      :claim -> resolve_claim_identity(account, identity_profile)
      :proof -> resolve_proof_identity(account, identity_profile)
    end
  end

  defp resolve_claim_identity(account, identity_profile) do
    with :ok <- enforce_verified_email(identity_profile) do
      upsert_verified_identity(account, identity_profile)
    end
  end

  defp upsert_verified_identity(account, identity_profile) do
    with {:ok, identity} <-
           Database.upsert_identity(
             account.id,
             identity_profile.email,
             identity_profile.issuer,
             identity_profile.idp_id,
             identity_profile.profile_attrs
           ) do
      {:ok, {:identity, identity}}
    end
  end

  defp resolve_proof_identity(account, identity_profile) do
    case Database.fetch_active_identity_by_idp(
           account.id,
           identity_profile.issuer,
           identity_profile.idp_id
         ) do
      {:ok, identity} ->
        with {:ok, identity} <-
               Database.update_identity_profile(identity, identity_profile.profile_attrs) do
          {:ok, {:identity, identity}}
        end

      {:error, :not_found} ->
        with {:ok, actor} <- Database.fetch_active_actor_by_email(account, identity_profile.email) do
          {:ok, {:proof_required, actor, identity_profile}}
        end
    end
  end

  # Google and Okta consistently return email_verified=true, so we enforce the claim
  # to surface any misbehavior. Entra does not set email_verified, so we cannot check it.
  # Generic OIDC providers send it inconsistently, so we let the admin choose via
  # email_verification_method (none/claim/proof).
  defp email_verification_method(%Portal.Google.AuthProvider{}), do: :claim
  defp email_verification_method(%Portal.Okta.AuthProvider{}), do: :claim

  defp email_verification_method(%Portal.OIDC.AuthProvider{email_verification_method: method}),
    do: method

  defp email_verification_method(_provider), do: :none

  defp enforce_verified_email(%IdentityProfile{email_verified: :verified}), do: :ok

  defp enforce_verified_email(%IdentityProfile{email_verified: :unverified}),
    do: {:error, :email_not_verified}

  defp enforce_verified_email(%IdentityProfile{email_verified: :missing}),
    do: {:error, :email_verified_missing}

  defp start_owner_verification(conn, account, provider, actor, identity_profile, params) do
    pending_identity_id = Ecto.UUID.generate()
    sign_in_params = sanitize(params)

    case create_pending_identity_verification(
           conn,
           account,
           provider,
           actor,
           pending_identity_id,
           identity_profile,
           sign_in_params
         ) do
      {:ok, _pending_identity, _passcode} ->
        cookie = %Cookie.PendingIdentity{
          pending_identity_id: pending_identity_id,
          params: sign_in_params
        }

        conn =
          conn
          |> Cookie.PendingIdentity.put(cookie)
          |> redirect(
            to:
              ~p"/#{account}/sign_in/oidc/#{provider.id}/verify_identity?#{verification_params(pending_identity_id, sign_in_params)}"
          )

        {:ok, conn}

      {:error, :rate_limited} ->
        Logger.info("OIDC identity verification email rate limited",
          account_slug: account.slug,
          auth_provider_id: provider.id
        )

        {:error, :rate_limited}

      error ->
        Logger.info("OIDC identity verification email not sent",
          account_slug: account.slug,
          auth_provider_id: provider.id,
          error: inspect(error)
        )

        error
    end
  end

  defp create_pending_identity_verification(
         conn,
         account,
         provider,
         actor,
         pending_identity_id,
         identity_profile,
         sign_in_params
       ) do
    with {:ok, passcode} <- Database.create_one_time_passcode(account, actor) do
      with {:ok, pending_identity} <-
             Database.insert_pending_identity(
               account,
               actor,
               provider,
               pending_identity_id,
               passcode,
               identity_profile
             ),
           {:ok, _email} <-
             send_identity_verification_email(
               conn,
               actor,
               provider,
               pending_identity_id,
               passcode.code,
               sign_in_params
             ) do
        {:ok, pending_identity, passcode}
      else
        {:error, _reason} = error ->
          :ok = Database.delete_one_time_passcode(passcode.account_id, passcode.id)
          error
      end
    end
  end

  defp send_identity_verification_email(
         conn,
         actor,
         provider,
         pending_identity_id,
         code,
         sign_in_params
       ) do
    context = authentication_context(conn, context_type(sign_in_params))

    Portal.Mailer.AuthEmail.oidc_identity_verification_email(
      actor,
      DateTime.utc_now(),
      provider.id,
      pending_identity_id,
      code,
      context,
      sign_in_params
    )
    |> Portal.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:oidc_identity_verification, actor.email},
      rate_limit: 3,
      rate_limit_interval: :timer.minutes(5)
    )
  end

  defp do_verify_identity(conn, params, entered_code) do
    case load_pending_identity_context(conn, params) do
      {:ok, context} ->
        run_pending_identity_verification(context, entered_code)

      error ->
        error
    end
  end

  defp load_pending_identity_context(conn, params) do
    with %Cookie.PendingIdentity{} = cookie <-
           Cookie.PendingIdentity.fetch(conn, params["pending_identity_id"]),
         {:ok, account} <- Database.fetch_account_by_id_or_slug(params["account_id_or_slug"]),
         {:ok, provider} <-
           Database.fetch_provider(account.id, "oidc", params["auth_provider_id"]) do
      sign_in_params = sanitize(cookie.params)
      conn = put_pending_identity_error_context(conn, account, provider.id, sign_in_params)

      {:ok,
       %{
         conn: conn,
         pending_identity_id: cookie.pending_identity_id,
         account: account,
         provider: provider,
         params: sign_in_params,
         context_type: context_type(sign_in_params)
       }}
    else
      _ -> {:error, :pending_identity_state_not_found}
    end
  end

  defp put_pending_identity_error_context(conn, account, auth_provider_id, sign_in_params) do
    Plug.Conn.assign(conn, :oidc_error_context, %{
      account_id: account.id,
      account_slug: account.slug,
      params: sign_in_params,
      auth_provider_id: auth_provider_id
    })
  end

  defp run_pending_identity_verification(
         %{
           conn: conn,
           pending_identity_id: pending_identity_id,
           account: account,
           provider: provider,
           params: params,
           context_type: context_type
         },
         entered_code
       ) do
    with :ok <- validate_context(provider, context_type),
         :ok <- ensure_client_sign_in_allowed(account, context_type),
         {:ok, identity, pending_identity_ids} <-
           Database.verify_and_promote_pending_identity(
             account.id,
             pending_identity_id,
             provider.id,
             entered_code
           ),
         :ok <- check_admin(identity, context_type),
         {:ok, session_or_token} <- create_session_or_token(conn, identity, provider, params) do
      {:ok,
       %{
         conn: conn,
         account: account,
         identity: identity,
         provider: provider,
         session_or_token: session_or_token,
         context_type: context_type,
         params: params,
         email: identity.email,
         pending_identity_ids: pending_identity_ids
       }}
    else
      error -> {:error, error, conn}
    end
  end

  defp handle_verify_identity_result(_conn, {:ok, result}, _params) do
    conn = Cookie.PendingIdentity.delete_all(result.conn, result.pending_identity_ids)
    :ok = Portal.Mailer.RateLimiter.reset_rate_limit({:oidc_identity_verification, result.email})

    signed_in(
      conn,
      result.context_type,
      result.account,
      result.identity,
      result.session_or_token,
      result.provider,
      %{},
      result.params
    )
  end

  defp handle_verify_identity_result(_conn, {:error, {:error, :invalid_code}, conn}, params) do
    redirect_pending_identity_error(
      conn,
      "The verification code is invalid or expired.",
      params
    )
  end

  defp handle_verify_identity_result(_conn, {:error, error, conn}, _params) do
    handle_error(conn, error)
  end

  defp handle_verify_identity_result(conn, error, _params) do
    handle_error(conn, error)
  end

  defp redirect_pending_identity_error(conn, error, params) do
    context = pending_identity_error_context(conn, params)

    path =
      ~p"/#{context.account_slug}/sign_in/oidc/#{context.auth_provider_id}/verify_identity?#{verification_params(params["pending_identity_id"], context.params)}"

    redirect_for_error(conn, error, path)
  end

  defp pending_identity_error_context(conn, params) do
    Map.merge(
      %{
        account_slug: params["account_id_or_slug"],
        auth_provider_id: params["auth_provider_id"],
        params: sanitize(params)
      },
      conn.assigns[:oidc_error_context] || %{}
    )
  end

  defp check_admin(
         %Portal.ExternalIdentity{actor: %Portal.Actor{type: :account_admin_user}},
         _context_type
       ),
       do: :ok

  defp check_admin(%Portal.ExternalIdentity{actor: actor}, context_type),
    do: check_actor(actor, context_type)

  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

  defp check_actor(%Portal.Actor{type: :account_admin_user}, _context_type), do: :ok

  defp check_actor(%Portal.Actor{type: :account_user}, t)
       when t in [:gui_client, :headless_client],
       do: :ok

  defp check_actor(_actor, _context_type), do: {:error, :not_admin}

  defp validate_context(%{context: context}, t)
       when t in [:gui_client, :headless_client] and
              context in [:clients_only, :clients_and_portal] do
    :ok
  end

  defp validate_context(%{context: context}, :portal)
       when context in [:portal_only, :clients_and_portal] do
    :ok
  end

  defp validate_context(_provider, _context_type), do: {:error, :invalid_context}

  defp ensure_client_sign_in_allowed(account, context_type)
       when context_type in [:gui_client, :headless_client] do
    if Portal.Billing.client_sign_in_restricted?(account) do
      {:error, :client_sign_in_restricted}
    else
      :ok
    end
  end

  defp ensure_client_sign_in_allowed(_account, _context_type), do: :ok

  defp create_session_or_token(conn, identity, provider, params) do
    type = context_type(params)
    context = authentication_context(conn, type)

    # Get the provider schema module to access default values
    schema = provider.__struct__

    # Determine session lifetime based on context type
    session_lifetime_secs = session_lifetime_secs(provider, schema, type)

    expires_at = DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second)

    case type do
      :portal ->
        Portal.Authentication.create_portal_session(
          identity.actor,
          provider.id,
          context,
          expires_at
        )

      :gui_client ->
        create_client_token(identity, provider, expires_at, params["nonce"])

      :headless_client ->
        create_client_token(identity, provider, expires_at, "")
    end
  end

  defp create_client_token(identity, provider, expires_at, nonce) do
    attrs = %{
      secret_nonce: nonce,
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      auth_provider_id: provider.id,
      identity_id: identity.id,
      expires_at: expires_at
    }

    Portal.Authentication.create_interactive_client_token(attrs)
  end

  defp session_lifetime_secs(provider, schema, type)
       when type in [:gui_client, :headless_client] do
    provider.client_session_lifetime_secs || schema.default_client_session_lifetime_secs()
  end

  defp session_lifetime_secs(provider, schema, :portal) do
    provider.portal_session_lifetime_secs || schema.default_portal_session_lifetime_secs()
  end

  # Context: :portal
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :portal, account, _identity, session, _provider, _tokens, params) do
    conn
    |> PortalWeb.Cookie.Session.put(account.id, %PortalWeb.Cookie.Session{session_id: session.id})
    |> Redirector.portal_signed_in(account, params)
  end

  # Context: :gui_client
  # Store a cookie and redirect to client handler which redirects to the final URL based on platform
  defp signed_in(conn, :gui_client, account, identity, token, _provider, _tokens, params) do
    Redirector.gui_client_signed_in(
      conn,
      account,
      identity.actor.name,
      identity.email,
      token,
      params["state"]
    )
  end

  # Context: :headless_client
  # Show the token to the user to copy manually
  defp signed_in(conn, :headless_client, account, identity, token, _provider, _tokens, params) do
    Redirector.headless_client_signed_in(
      conn,
      account,
      identity.actor.name,
      token,
      params["state"]
    )
  end

  defp context_type(%{"as" => "client"}), do: :gui_client
  defp context_type(%{"as" => "gui-client"}), do: :gui_client
  defp context_type(%{"as" => "headless-client"}), do: :headless_client
  defp context_type(_), do: :portal

  defp authentication_context(conn, type) do
    Portal.Authentication.Context.build(
      conn.remote_ip,
      conn.assigns[:user_agent] || "",
      conn.req_headers,
      type
    )
  end

  defp handle_error(conn, {:error, reason})
       when reason in [
              :oidc_state_not_found,
              :oidc_state_session_mismatch,
              :pending_identity_state_not_found
            ] do
    error = "Your sign-in session has timed out. Please try again."
    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, :rate_limited}) do
    error = "You're attempting to do that too quickly. Wait a few minutes and try again."
    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, :not_admin}) do
    error = "This action requires admin privileges."
    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, :actor_not_found}) do
    error = "Unable to sign you in. Please contact your administrator."
    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, :invalid_context}) do
    error = "This authentication method is not available for your sign-in context."
    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, :client_sign_in_restricted}) do
    error =
      "This account is temporarily suspended from client authentication " <>
        "due to exceeding billing limits. Please contact your administrator to add more seats."

    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, reason})
       when reason in [:email_not_verified, :email_verified_missing] do
    redirect_with_error_context(conn, @unverified_email_error)
  end

  defp handle_error(conn, {:error, :invalid_callback_params}) do
    error = "Invalid sign-in request. Please try again."
    redirect_with_error_context(conn, error)
  end

  # Transport errors (network issues)
  defp handle_error(conn, {:error, %Req.TransportError{reason: reason}}) do
    redirect_with_error_context(conn, identity_provider_transport_error_message(reason))
  end

  # HTTP error status codes from token endpoint
  defp handle_error(conn, {:error, {status, body}}) when is_integer(status) do
    redirect_with_error_context(conn, token_exchange_error_message(status, body))
  end

  # JWT verification failures
  defp handle_error(conn, {:error, {:invalid_jwt, reason}}) do
    Logger.warning("OIDC token verification failed", reason: reason)
    error = "Unable to verify your identity token. Please try signing in again."
    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, %Ecto.Changeset{} = changeset}) do
    account_id = Ecto.Changeset.get_field(changeset, :account_id)
    idp_id = Ecto.Changeset.get_field(changeset, :idp_id)

    provider_id = get_in(conn.assigns, [:oidc_error_context, :auth_provider_id])

    for {field, _errors} <- changeset.errors do
      value = Ecto.Changeset.get_field(changeset, field)
      length = if is_binary(value), do: String.length(value), else: nil

      Logger.warning("OIDC profile validation failed",
        account_id: account_id,
        provider_id: provider_id,
        idp_id: idp_id,
        field: field,
        length: length
      )
    end

    error =
      "Your identity provider returned invalid profile data. Please contact your administrator."

    redirect_with_error_context(conn, error)
  end

  defp handle_error(conn, {:error, reason}) do
    Logger.warning("OIDC sign-in error", reason: reason)
    error = "An unexpected error occurred while signing you in. Please try again."
    redirect_with_error_context(conn, error)
  end

  defp fetch_error_context(conn) do
    case conn.assigns[:oidc_error_context] do
      %{account_id: account_id, account_slug: slug, params: params} ->
        {account_id, slug, params || %{}}

      nil ->
        {nil, "", %{}}
    end
  end

  defp put_oidc_error_context(conn, %Cookie.AuthenticationState{} = cookie) do
    Plug.Conn.assign(conn, :oidc_error_context, %{
      account_id: cookie.account_id,
      account_slug: cookie.account_slug,
      params: cookie.params || %{},
      auth_provider_id: cookie.auth_provider_id
    })
  end

  defp handle_oidc_verification(conn, code, lv_pid_string) do
    result =
      lv_pid_string
      |> PortalWeb.OIDC.deserialize_pid()
      |> request_pending_verification()
      |> verify_oidc_callback(code, lv_pid_string)

    token = Phoenix.Token.sign(PortalWeb.Endpoint, "oidc-verification-result", result)
    redirect(conn, to: ~p"/verification/oidc?result=#{token}")
  end

  defp verify_oidc_callback(
         {:ok, %{config: config, verifier: verifier} = pending},
         code,
         lv_pid_string
       ) do
    with {:ok, claims, userinfo_result} <- PortalWeb.OIDC.verify_callback(config, code, verifier),
         :ok <- verify_email_verified_claim(pending, claims, userinfo_result) do
      %{
        ok: true,
        issuer: claims["iss"],
        lv_pid: lv_pid_string,
        verification_ref: pending[:verification_ref]
      }
    else
      {:error, reason} ->
        maybe_log_verification_error(reason)

        %{
          ok: false,
          error: verification_error_message(reason),
          lv_pid: lv_pid_string
        }
    end
  end

  defp verify_oidc_callback({:error, reason}, _code, lv_pid_string) do
    %{ok: false, error: pending_verification_error_message(reason), lv_pid: lv_pid_string}
  end

  defp verify_email_verified_claim(
         %{require_email_verified: true},
         %{"email_verified" => true},
         _userinfo_result
       ) do
    :ok
  end

  defp verify_email_verified_claim(
         %{require_email_verified: true},
         %{"email_verified" => _value},
         _userinfo_result
       ) do
    {:error, :email_not_verified}
  end

  defp verify_email_verified_claim(%{require_email_verified: true}, claims, {:ok, userinfo}) do
    case PortalWeb.OIDC.email_verified_status(claims, userinfo) do
      :verified -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  defp verify_email_verified_claim(%{require_email_verified: true}, _claims, {:error, reason}) do
    {:error, reason}
  end

  defp verify_email_verified_claim(_pending, _claims, _userinfo_result), do: :ok

  defp request_pending_verification(nil), do: {:error, :no_pid}

  defp request_pending_verification(lv_pid) do
    send(lv_pid, {:get_pending_verification, self()})

    receive do
      {:pending_verification, pending} when is_map(pending) -> {:ok, pending}
      {:pending_verification, _} -> {:error, :not_found}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp pending_verification_error_message(reason)
       when reason in [:no_pid, :not_found, :timeout] do
    "Verification session was not found or has expired. Please retry verification."
  end

  defp pending_verification_error_message(_reason) do
    "Unable to load verification session. Please retry verification."
  end

  defp maybe_log_verification_error(:email_not_verified), do: :ok

  defp maybe_log_verification_error(reason) do
    Logger.warning("OIDC verification failed", reason: inspect(reason))
  end

  defp verification_error_message(%Req.TransportError{reason: reason}) do
    identity_provider_transport_error_message(reason)
  end

  defp verification_error_message({status, body}) when is_integer(status) do
    token_exchange_error_message(status, body)
  end

  defp verification_error_message({:invalid_jwt, _reason}) do
    "Unable to verify your identity token. Please try again."
  end

  defp verification_error_message(:email_not_verified) do
    @unverified_email_error
  end

  defp verification_error_message(_reason) do
    "Verification failed. Please try again."
  end

  defp parse_callback_state(state) do
    case PortalWeb.OIDC.verify_verification_state(state) do
      {:ok, %{type: "oidc-auth-provider", lv_pid: lv_pid}} -> {:oidc_verification, lv_pid}
      {:ok, %{type: "entra-auth-provider", lv_pid: lv_pid}} -> {:entra_auth_provider, lv_pid}
      {:ok, %{type: "entra-directory-sync", lv_pid: lv_pid}} -> {:entra_directory_sync, lv_pid}
      {:error, _} -> :authentication
    end
  end

  defp identity_provider_transport_error_message(:nxdomain),
    do:
      "Unable to reach identity provider: DNS lookup failed. Please verify the provider's domain is correct."

  defp identity_provider_transport_error_message(:econnrefused),
    do:
      "Unable to reach identity provider: Connection refused. The provider may be down or blocking requests."

  defp identity_provider_transport_error_message(:timeout),
    do: "Unable to reach identity provider: Connection timed out. Please try again."

  defp identity_provider_transport_error_message(_reason),
    do: "Unable to reach identity provider. Please check your network connection and try again."

  defp token_exchange_error_message(401, _body),
    do:
      "Identity provider rejected the credentials. Please verify your Client ID and Client Secret are correct."

  defp token_exchange_error_message(400, %{"error" => "invalid_grant"}),
    do: "The authorization code has expired or was already used. Please try signing in again."

  defp token_exchange_error_message(400, %{"error" => "invalid_client"}),
    do:
      "Identity provider rejected the client credentials. Please verify your Client ID and Client Secret."

  defp token_exchange_error_message(400, %{"error" => _error_code}),
    do: "Identity provider returned an error while signing you in. Please try again."

  defp token_exchange_error_message(status, _body) when status in 500..599,
    do: "Identity provider returned a server error (HTTP #{status}). Please try again later."

  defp token_exchange_error_message(status, _body),
    do: "Identity provider returned an error (HTTP #{status}). Please try again."

  defp invalid_json_reason?(reason) do
    match?({:unexpected_end, _}, reason) or
      match?({tag, _, _} when tag in [:invalid_byte, :unexpected_sequence], reason)
  end

  defp redirect_for_error(conn, error, path) do
    conn
    |> put_flash(:error, error)
    |> redirect(to: path)
    |> halt()
  end

  defp redirect_with_error_context(conn, error) do
    {account_id, account_slug, original_params} = fetch_error_context(conn)
    log_sign_in_redirect_error(account_id, error)
    redirect_for_error(conn, error, error_path_for_context(account_slug, original_params, error))
  end

  defp log_sign_in_redirect_error(nil, _error), do: :ok

  defp log_sign_in_redirect_error(account_id, error) do
    Logger.info("OIDC sign-in redirecting with error",
      account_id: account_id,
      error: error
    )
  end

  defp error_path("", _params), do: ~p"/sign_in"
  defp error_path(account, params), do: ~p"/#{account}/sign_in?#{sanitize(params)}"

  defp error_path_for_context(account, params, error) do
    if client_context?(params) and account != "" do
      ~p"/#{account}/sign_in/client_auth_error?#{client_error_params(params, error)}"
    else
      error_path(account, params)
    end
  end

  defp client_error_params(params, error) do
    params
    |> sanitize()
    |> Map.put("error", error)
  end

  defp sanitize(params) do
    Map.take(params, ["as", "redirect_to", "state", "nonce"])
  end

  defp verification_params(pending_identity_id, params) do
    params
    |> sanitize()
    |> Map.put("pending_identity_id", pending_identity_id)
  end

  defp client_context?(%{"as" => as}) when as in ["client", "gui-client", "headless-client"],
    do: true

  defp client_context?(_params), do: false

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Safe, AuthProvider, ExternalIdentity, PendingIdentity, OneTimePasscode}
    alias Portal.Account

    @otp_expiration_seconds 15 * 60

    @profile_fields ~w[
      email
      name
      given_name
      family_name
      middle_name
      nickname
      preferred_username
      profile
      picture
      firezone_avatar_url
    ]a

    @pending_identity_profile_fields @profile_fields -- [:firezone_avatar_url]

    def get_account_by_id_or_slug!(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped(:replica) |> Safe.one!()
    end

    def fetch_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
      |> case do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end

    def get_provider!(account_id, type, id) do
      schema = AuthProvider.module!(type)

      from(p in schema,
        where: p.account_id == ^account_id and p.id == ^id and p.is_disabled == false
      )
      |> Safe.unscoped(:replica)
      |> Safe.one!()
    end

    def fetch_provider(account_id, type, id) do
      schema = AuthProvider.module!(type)

      from(p in schema,
        where: p.account_id == ^account_id and p.id == ^id and p.is_disabled == false
      )
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
      |> case do
        nil -> {:error, :not_found}
        provider -> {:ok, provider}
      end
    end

    def fetch_active_identity_by_idp(account_id, issuer, idp_id) do
      from(identity in ExternalIdentity,
        join: actor in assoc(identity, :actor),
        where: identity.account_id == ^account_id,
        where: identity.issuer == ^issuer,
        where: identity.idp_id == ^idp_id,
        where: is_nil(actor.disabled_at),
        preload: [:account, actor: actor]
      )
      |> Safe.unscoped(:replica)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        identity -> {:ok, identity}
      end
    end

    def fetch_active_actor_by_email(account, email) do
      email = trim_email(email)

      from(actor in Portal.Actor,
        where: actor.account_id == ^account.id,
        where: actor.type in [:account_admin_user, :account_user],
        where: is_nil(actor.disabled_at),
        where: actor.email == ^email,
        preload: [:account],
        limit: 1
      )
      |> Safe.unscoped(:replica)
      |> Safe.one()
      |> case do
        nil -> {:error, :actor_not_found}
        actor -> {:ok, actor}
      end
    end

    def update_identity_profile(%ExternalIdentity{} = identity, profile_attrs) do
      identity
      |> cast(atomize_profile_attrs(profile_attrs), @profile_fields)
      |> ExternalIdentity.changeset()
      |> Safe.unscoped()
      |> Safe.update()
      |> case do
        {:ok, identity} -> {:ok, Safe.preload(identity, [:actor, :account], :replica)}
        error -> error
      end
    end

    def insert_pending_identity(
          account,
          actor,
          provider,
          pending_identity_id,
          passcode,
          identity_profile
        ) do
      attrs =
        identity_profile.profile_attrs
        |> atomize_profile_attrs()
        |> Map.merge(%{
          id: pending_identity_id,
          account_id: account.id,
          actor_id: actor.id,
          auth_provider_id: provider.id,
          one_time_passcode_id: passcode.id,
          issuer: identity_profile.issuer,
          idp_id: identity_profile.idp_id
        })

      %PendingIdentity{}
      |> cast(
        attrs,
        [
          :id,
          :account_id,
          :actor_id,
          :auth_provider_id,
          :one_time_passcode_id,
          :issuer,
          :idp_id,
          :directory_id | @pending_identity_profile_fields
        ]
      )
      |> PendingIdentity.changeset()
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def create_one_time_passcode(account, actor) do
      code = Portal.Crypto.random_token(6, encoder: :user_friendly)
      code_hash = Portal.Crypto.hash(:argon2, code)
      expires_at = DateTime.utc_now() |> DateTime.add(@otp_expiration_seconds, :second)

      %OneTimePasscode{
        account_id: account.id,
        actor_id: actor.id,
        code: code,
        code_hash: code_hash,
        expires_at: expires_at
      }
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def verify_and_promote_pending_identity(
          account_id,
          pending_identity_id,
          auth_provider_id,
          entered_code
        ) do
      Safe.transact(fn ->
        with {:ok, pending_identity} <-
               fetch_pending_identity_for_update(
                 account_id,
                 pending_identity_id,
                 auth_provider_id
               ),
             {:ok, passcode} <- fetch_pending_passcode_for_update(pending_identity) do
          verify_and_promote(pending_identity, passcode, entered_code)
        else
          {:error, :not_found} ->
            dummy_verify_pending_identity_code()
            {:ok, :not_found}
        end
      end)
      |> case do
        {:ok, {:verified, %ExternalIdentity{} = identity, pending_identity_ids}} ->
          {:ok, Safe.preload(identity, [:actor, :account], :replica), pending_identity_ids}

        {:ok, :invalid_code} ->
          {:error, :invalid_code}

        {:ok, :not_found} ->
          {:error, :invalid_code}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp verify_and_promote(
           %PendingIdentity{} = pending_identity,
           %OneTimePasscode{} = passcode,
           entered_code
         ) do
      if Portal.Crypto.equal?(:argon2, entered_code, passcode.code_hash) do
        pending_identity_ids = fetch_related_pending_identity_ids(pending_identity)

        with {:ok, identity} <- insert_external_identity_from_pending(pending_identity),
             :ok <- delete_related_pending_identities_and_passcodes(pending_identity) do
          {:ok, {:verified, identity, pending_identity_ids}}
        end
      else
        :ok = record_failed_one_time_passcode_attempt(passcode)
        {:ok, :invalid_code}
      end
    end

    defp record_failed_one_time_passcode_attempt(%OneTimePasscode{} = passcode) do
      from(otp in OneTimePasscode,
        where: otp.account_id == ^passcode.account_id,
        where: otp.id == ^passcode.id,
        update: [inc: [attempts: 1]],
        select: otp.attempts
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
      |> case do
        {1, [attempts]} ->
          if attempts >= OneTimePasscode.max_attempts() do
            delete_one_time_passcode(passcode.account_id, passcode.id)
          else
            :ok
          end

        _ ->
          :ok
      end
    end

    defp dummy_verify_pending_identity_code do
      Portal.Crypto.equal?(:argon2, nil, nil)
      :ok
    end

    def delete_one_time_passcode(account_id, passcode_id) do
      from(passcode in OneTimePasscode,
        where: passcode.account_id == ^account_id,
        where: passcode.id == ^passcode_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()

      :ok
    end

    def upsert_identity(account_id, email, issuer, idp_id, profile_attrs) do
      now = DateTime.utc_now()
      account_id_bytes = Ecto.UUID.dump!(account_id)

      replace_fields = [
        :idp_id,
        :email,
        :name,
        :given_name,
        :family_name,
        :middle_name,
        :nickname,
        :preferred_username,
        :profile,
        :picture,
        :updated_at
      ]

      actor_lookup_cte =
        from(a in "actors",
          where:
            a.account_id == ^account_id_bytes and
              a.email == ^email and
              is_nil(a.disabled_at),
          select: %{id: a.id},
          limit: 1
        )

      # Match the existing identity by idp_id (stable subject) or, since the
      # email is verified on this path, by the actor's email. The latter lets a
      # user who was deleted and recreated in the IdP (new idp_id, same email)
      # overwrite their existing identity in place instead of inserting a second
      # row, which would later collide with directory sync on the
      # (account_id, actor_id, directory_id) unique index. Prefer the email
      # match so a recreated user recycles their own row.
      existing_identity_cte =
        from(ei in "external_identities",
          join: a in "actors",
          on: a.id == ei.actor_id,
          where:
            ei.account_id == ^account_id_bytes and
              ei.issuer == ^issuer and
              is_nil(a.disabled_at) and
              (ei.idp_id == ^idp_id or a.email == ^email),
          order_by: [desc: fragment("(? = ?)", a.email, ^email)],
          select: %{id: ei.id, actor_id: ei.actor_id},
          limit: 1
        )

      base_query =
        from(d in fragment("SELECT 1"),
          left_join: al in "actor_lookup",
          on: true,
          left_join: ei in "existing_identity",
          on: true,
          where: not is_nil(al.id) or not is_nil(ei.actor_id),
          select: %{
            id: fragment("COALESCE(?.id, uuid_generate_v4())", ei),
            account_id: ^account_id_bytes,
            issuer: ^issuer,
            idp_id: ^idp_id,
            actor_id: fragment("COALESCE(?.actor_id, ?.id)", ei, al),
            email: ^profile_attrs["email"],
            name: ^profile_attrs["name"],
            given_name: ^profile_attrs["given_name"],
            family_name: ^profile_attrs["family_name"],
            middle_name: ^profile_attrs["middle_name"],
            nickname: ^profile_attrs["nickname"],
            preferred_username: ^profile_attrs["preferred_username"],
            profile: ^profile_attrs["profile"],
            picture: ^profile_attrs["picture"],
            inserted_at: ^now,
            updated_at: ^now
          }
        )

      query_with_ctes =
        base_query
        |> with_cte("actor_lookup", as: ^actor_lookup_cte)
        |> with_cte("existing_identity", as: ^existing_identity_cte)

      {count, rows} = insert_identity(query_with_ctes, replace_fields)

      case {count, rows} do
        {0, _} ->
          # Neither actor_lookup nor existing_identity matched → no identity
          {:error, :actor_not_found}

        {_, [%ExternalIdentity{} = identity]} ->
          # actor and account are long-lived records, safe to read from replica
          {:ok, Safe.preload(identity, [:actor, :account], :replica)}
      end
    end

    # Two concurrent sign-ins for the same brand-new (account_id, idp_id, issuer)
    # can each generate a different id and race to insert. The (account_id, id)
    # conflict target won't catch the loser, so it raises a unique violation on
    # external_identities_account_idp_fields_index. On retry the committed row is
    # found by existing_identity and recycled in place via the PK conflict.
    defp insert_identity(query_with_ctes, replace_fields, retry? \\ true) do
      Safe.insert_all(
        Safe.unscoped(),
        ExternalIdentity,
        query_with_ctes,
        on_conflict: {:replace, replace_fields},
        conflict_target: [:account_id, :id],
        returning: true
      )
    rescue
      e in Postgrex.Error ->
        case e do
          %Postgrex.Error{postgres: %{code: :unique_violation}} when retry? ->
            insert_identity(query_with_ctes, replace_fields, false)

          _ ->
            reraise e, __STACKTRACE__
        end
    end

    defp fetch_related_pending_identity_ids(%PendingIdentity{} = pending_identity) do
      from(identity in PendingIdentity,
        where: identity.account_id == ^pending_identity.account_id,
        where: identity.actor_id == ^pending_identity.actor_id,
        where: identity.issuer == ^pending_identity.issuer,
        where: identity.idp_id == ^pending_identity.idp_id,
        select: identity.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp delete_related_pending_identities_and_passcodes(%PendingIdentity{} = pending_identity) do
      related_passcode_ids =
        from(identity in PendingIdentity,
          where: identity.account_id == ^pending_identity.account_id,
          where: identity.actor_id == ^pending_identity.actor_id,
          where: identity.issuer == ^pending_identity.issuer,
          where: identity.idp_id == ^pending_identity.idp_id,
          select: identity.one_time_passcode_id
        )

      # The pending_identities rows are removed by the one_time_passcode_id
      # foreign key's ON DELETE CASCADE.
      from(passcode in OneTimePasscode,
        where: passcode.account_id == ^pending_identity.account_id,
        where: passcode.id in subquery(related_passcode_ids)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()

      :ok
    end

    defp fetch_pending_passcode_for_update(%PendingIdentity{} = pending_identity) do
      from(passcode in OneTimePasscode,
        join: actor in assoc(passcode, :actor),
        where: passcode.account_id == ^pending_identity.account_id,
        where: passcode.actor_id == ^pending_identity.actor_id,
        where: passcode.id == ^pending_identity.one_time_passcode_id,
        where: passcode.expires_at > ^DateTime.utc_now(),
        where: passcode.attempts < ^OneTimePasscode.max_attempts(),
        where: is_nil(actor.disabled_at),
        lock: "FOR UPDATE"
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        passcode -> {:ok, passcode}
      end
    end

    defp fetch_pending_identity_for_update(account_id, pending_identity_id, auth_provider_id) do
      from(identity in PendingIdentity,
        where: identity.account_id == ^account_id,
        where: identity.id == ^pending_identity_id,
        where: identity.auth_provider_id == ^auth_provider_id,
        lock: "FOR UPDATE"
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        identity -> {:ok, identity}
      end
    end

    defp insert_external_identity_from_pending(%PendingIdentity{} = pending_identity) do
      now = DateTime.utc_now()

      attrs =
        pending_identity
        |> Map.from_struct()
        |> Map.take([
          :id,
          :account_id,
          :actor_id,
          :issuer,
          :idp_id,
          :directory_id | @pending_identity_profile_fields
        ])
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      case Safe.insert_all(
             Safe.unscoped(),
             ExternalIdentity,
             [attrs],
             on_conflict: external_identity_conflict_query(pending_identity),
             conflict_target: [:account_id, :idp_id, :issuer],
             returning: true
           ) do
        {1, [%ExternalIdentity{} = identity]} -> {:ok, identity}
        {0, []} -> {:error, :invalid_code}
      end
    end

    defp external_identity_conflict_query(%PendingIdentity{} = pending_identity) do
      from(identity in ExternalIdentity,
        where: identity.actor_id == ^pending_identity.actor_id,
        update: [
          set: [
            email: fragment("EXCLUDED.email"),
            name: fragment("EXCLUDED.name"),
            given_name: fragment("EXCLUDED.given_name"),
            family_name: fragment("EXCLUDED.family_name"),
            middle_name: fragment("EXCLUDED.middle_name"),
            nickname: fragment("EXCLUDED.nickname"),
            preferred_username: fragment("EXCLUDED.preferred_username"),
            profile: fragment("EXCLUDED.profile"),
            picture: fragment("EXCLUDED.picture"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )
    end

    defp atomize_profile_attrs(attrs) do
      Map.new(attrs, fn
        {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
        {key, value} -> {key, value}
      end)
    end

    defp trim_email(email) when is_binary(email), do: String.trim(email)

    defp trim_email(email), do: email
  end
end
