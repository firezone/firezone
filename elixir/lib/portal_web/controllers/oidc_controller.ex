defmodule PortalWeb.OIDCController do
  use PortalWeb, :controller

  alias Portal.AuthProvider

  alias __MODULE__.Database

  alias PortalWeb.OIDC.IdentityProfile
  alias PortalWeb.Session.Redirector

  require Logger

  @invalid_json_error_message "Discovery document contains invalid JSON. Please verify the Discovery Document URI returns valid OpenID Connect configuration."
  @oidc_auth_ttl :timer.minutes(5)
  @oidc_state_session_key :oidc_state_binding

  @spec sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    account = Database.get_account_by_id_or_slug!(account_id_or_slug)
    provider = get_provider!(account, params)
    provider_redirect(conn, account, provider, params)
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"state" => state, "code" => code}) do
    case parse_callback_state(state) do
      {:oidc_verification, verification_token} ->
        handle_verification_callback(conn, verification_token, code)

      _ ->
        handle_authentication_callback(conn, state, code)
    end
  end

  # Handle Entra admin consent callback (returns admin_consent & tenant instead of code)
  def callback(conn, %{"state" => state, "admin_consent" => _, "tenant" => _} = params) do
    case parse_callback_state(state) do
      {:entra_verification, verification_token} ->
        handle_entra_verification_callback(conn, verification_token, params, "auth_provider")

      {:entra_admin_consent, verification_token} ->
        handle_entra_verification_callback(conn, verification_token, params, "directory_sync")

      _ ->
        handle_error(conn, {:error, :invalid_callback_params})
    end
  end

  def callback(conn, params) do
    Logger.info("OIDC callback called with invalid params", params: Map.keys(params))

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
    with {:ok, auth_state} <- fetch_oidc_auth_state(state),
         :ok <- verify_oidc_state_session_binding(conn, auth_state) do
      conn = put_oidc_error_context(conn, auth_state)
      params = auth_state.params || %{}
      context_type = context_type(params)
      account = Database.get_account_by_id_or_slug!(auth_state.account_id)
      provider = get_provider!(account, auth_state)

      {:ok,
       %{
         conn: conn,
         params: params,
         verifier: auth_state.verifier,
         context_type: context_type,
         account: account,
         provider: provider
       }}
    end
  end

  defp run_authentication_flow(auth_context, code) do
    %{
      conn: conn,
      params: params,
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
         {:ok, identity} <- upsert_identity(account, claims, userinfo),
         :ok <- check_admin(identity, context_type),
         {:ok, session_or_token} <-
           create_session_or_token(conn, identity, provider, params) do
      signed_in(
        conn,
        context_type,
        account,
        identity,
        session_or_token,
        provider,
        tokens,
        params
      )
    else
      error -> handle_error(conn, error)
    end
  end

  defp fetch_oidc_auth_state(state) do
    case Portal.AuthenticationCache.pop(Portal.AuthenticationCache.oidc_auth_key(state)) do
      {:ok, auth_state} -> {:ok, normalize_auth_state(auth_state)}
      :error -> {:error, :oidc_state_not_found}
    end
  end

  defp handle_verification_callback(conn, verification_token, code) do
    :ok =
      Portal.AuthenticationCache.put(
        Portal.AuthenticationCache.verification_key(verification_token),
        %{
          "type" => "oidc",
          "token" => verification_token,
          "code" => code
        }
      )

    # Store OIDC verification info in session for the LiveView to pick up
    conn
    |> put_session(:verification, %{
      "type" => "oidc",
      "token" => verification_token
    })
    |> redirect(to: ~p"/verification")
  end

  defp handle_entra_verification_callback(conn, verification_token, params, entra_type) do
    :ok =
      Portal.AuthenticationCache.put(
        Portal.AuthenticationCache.verification_key(verification_token),
        %{
          "type" => "entra",
          "entra_type" => entra_type,
          "token" => verification_token,
          "admin_consent" => params["admin_consent"],
          "tenant_id" => params["tenant"],
          "error" => params["error"],
          "error_description" => params["error_description"]
        }
      )

    # Store only minimal reference in session for the LiveView to pick up
    conn
    |> put_session(:verification, %{
      "type" => "entra",
      "token" => verification_token
    })
    |> redirect(to: ~p"/verification")
  end

  defp provider_redirect(conn, account, provider, params) do
    {conn, session_binding} = ensure_oidc_state_session_binding(conn)

    opts = authorization_opts(provider)

    case PortalWeb.OIDC.authorization_uri(provider, opts) do
      {:ok, uri, state, verifier} ->
        auth_state = %{
          auth_provider_type: params["auth_provider_type"],
          auth_provider_id: params["auth_provider_id"],
          account_id: account.id,
          account_slug: account.slug,
          verifier: verifier,
          session_binding: session_binding,
          params: sanitize(params)
        }

        :ok =
          Portal.AuthenticationCache.put(
            Portal.AuthenticationCache.oidc_auth_key(state),
            auth_state,
            ttl: @oidc_auth_ttl
          )

        conn
        |> redirect(external: uri)

      {:error, reason} ->
        handle_authorization_uri_error(conn, account, provider, reason)
    end
  end

  defp handle_authorization_uri_error(conn, account, provider, reason) do
    Logger.warning("OIDC authorization URI error",
      account_id: account.id,
      provider_id: provider.id,
      reason: authorization_error_reason(reason)
    )

    error = authorization_error_message(reason)

    conn
    |> put_flash(:error, error)
    |> redirect(to: ~p"/#{account.slug}")
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

  defp transport_error_message(reason),
    do:
      "Unable to fetch discovery document: #{inspect(reason)}. Please check the Discovery Document URI."

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

  defp discovery_error_message(reason) do
    if invalid_json_reason?(reason) do
      @invalid_json_error_message
    else
      "Unable to connect to the identity provider: #{inspect(reason)}. Please try again or contact your administrator."
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

  defp upsert_identity(account, claims, userinfo) do
    with {:ok, identity_profile} <- IdentityProfile.build(claims, userinfo, account.id) do
      maybe_log_unverified_email(account, identity_profile)

      Database.upsert_identity(
        account.id,
        identity_profile.email,
        identity_profile.issuer,
        identity_profile.idp_id,
        identity_profile.profile_attrs
      )
    end
  end

  defp maybe_log_unverified_email(_account, %{email_verified: true}), do: :ok

  defp maybe_log_unverified_email(account, %{email_verified: false, issuer: issuer}) do
    # In production, admins should hopefully ensure emails are verified.
    # If this does not occur regularly we might consider enforcing it in the future.
    Logger.info("OIDC identity email not verified",
      account_id: account.id,
      account_slug: account.slug,
      issuer: issuer
    )
  end

  defp check_admin(
         %Portal.ExternalIdentity{actor: %Portal.Actor{type: :account_admin_user}},
         _context_type
       ),
       do: :ok

  defp check_admin(%Portal.ExternalIdentity{actor: %Portal.Actor{type: :account_user}}, t)
       when t in [:gui_client, :headless_client],
       do: :ok

  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

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
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Portal.Authentication.Context.build(remote_ip, user_agent, headers, type)

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

    Portal.Authentication.create_gui_client_token(attrs)
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
      identity.email || identity.actor.email,
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

  defp handle_error(conn, {:error, reason})
       when reason in [:oidc_state_not_found, :oidc_state_session_mismatch] do
    error = "Your sign-in session has timed out. Please try again."
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
    error = "Failed to verify identity token: #{reason}. Please try signing in again."
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
      %{account_slug: slug, params: params} -> {slug, params || %{}}
      nil -> {"", %{}}
    end
  end

  defp put_oidc_error_context(conn, auth_state) do
    Plug.Conn.assign(conn, :oidc_error_context, %{
      account_slug: auth_state.account_slug,
      params: auth_state.params || %{},
      auth_provider_id: auth_state.auth_provider_id
    })
  end

  defp parse_callback_state(state) do
    case String.split(state, ":", parts: 2) do
      ["oidc-verification", token] -> {:oidc_verification, token}
      ["entra-verification", token] -> {:entra_verification, token}
      ["entra-admin-consent", token] -> {:entra_admin_consent, token}
      _ -> :authentication
    end
  end

  defp ensure_oidc_state_session_binding(conn) do
    case get_session(conn, @oidc_state_session_key) do
      binding when is_binary(binding) ->
        {conn, binding}

      _ ->
        binding = Portal.Crypto.random_token(32)
        {put_session(conn, @oidc_state_session_key, binding), binding}
    end
  end

  defp verify_oidc_state_session_binding(conn, %{session_binding: expected_binding})
       when is_binary(expected_binding) do
    case get_session(conn, @oidc_state_session_key) do
      ^expected_binding -> :ok
      _ -> {:error, :oidc_state_session_mismatch}
    end
  end

  defp verify_oidc_state_session_binding(_conn, _auth_state),
    do: {:error, :oidc_state_session_mismatch}

  defp identity_provider_transport_error_message(:nxdomain),
    do:
      "Unable to reach identity provider: DNS lookup failed. Please verify the provider's domain is correct."

  defp identity_provider_transport_error_message(:econnrefused),
    do:
      "Unable to reach identity provider: Connection refused. The provider may be down or blocking requests."

  defp identity_provider_transport_error_message(:timeout),
    do: "Unable to reach identity provider: Connection timed out. Please try again."

  defp identity_provider_transport_error_message(reason),
    do:
      "Unable to reach identity provider: #{inspect(reason)}. Please check your network connection and try again."

  defp token_exchange_error_message(401, _body),
    do:
      "Identity provider rejected the credentials. Please verify your Client ID and Client Secret are correct."

  defp token_exchange_error_message(400, %{"error" => "invalid_grant"}),
    do: "The authorization code has expired or was already used. Please try signing in again."

  defp token_exchange_error_message(400, %{"error" => "invalid_client"}),
    do:
      "Identity provider rejected the client credentials. Please verify your Client ID and Client Secret."

  defp token_exchange_error_message(400, %{"error" => error_code}),
    do: "Identity provider returned an error: #{error_code}. Please try again."

  defp token_exchange_error_message(status, _body) when status in 500..599,
    do: "Identity provider returned a server error (HTTP #{status}). Please try again later."

  defp token_exchange_error_message(status, _body),
    do: "Identity provider returned an error (HTTP #{status}). Please try again."

  defp invalid_json_reason?(reason) do
    match?({:unexpected_end, _}, reason) or
      match?({tag, _, _} when tag in [:invalid_byte, :unexpected_sequence], reason)
  end

  defp normalize_auth_state(auth_state) do
    %{
      auth_provider_type: auth_state_value(auth_state, :auth_provider_type),
      auth_provider_id: auth_state_value(auth_state, :auth_provider_id),
      account_id: auth_state_value(auth_state, :account_id),
      account_slug: auth_state_value(auth_state, :account_slug),
      verifier: auth_state_value(auth_state, :verifier),
      session_binding: auth_state_value(auth_state, :session_binding),
      params: auth_state_value(auth_state, :params) || %{}
    }
  end

  defp auth_state_value(auth_state, key) do
    case Map.get(auth_state, key) do
      nil -> Map.get(auth_state, Atom.to_string(key))
      value -> value
    end
  end

  defp redirect_for_error(conn, error, path) do
    conn
    |> put_flash(:error, error)
    |> redirect(to: path)
    |> halt()
  end

  defp redirect_with_error_context(conn, error) do
    {account_slug, original_params} = fetch_error_context(conn)
    redirect_for_error(conn, error, error_path(account_slug, original_params))
  end

  defp error_path(account_slug, params), do: ~p"/#{account_slug}?#{sanitize(params)}"

  defp sanitize(params) do
    Map.take(params, ["as", "redirect_to", "state", "nonce"])
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, AuthProvider, ExternalIdentity}
    alias Portal.Account

    def get_account_by_id_or_slug!(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped(:replica) |> Safe.one!()
    end

    def get_provider!(account_id, type, id) do
      schema = AuthProvider.module!(type)

      from(p in schema,
        where: p.account_id == ^account_id and p.id == ^id and p.is_disabled == false
      )
      |> Safe.unscoped(:replica)
      |> Safe.one!()
    end

    def upsert_identity(account_id, email, issuer, idp_id, profile_attrs) do
      now = DateTime.utc_now()
      account_id_bytes = Ecto.UUID.dump!(account_id)

      replace_fields = [
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

      existing_identity_cte =
        from(ei in "external_identities",
          join: a in "actors",
          on: a.id == ei.actor_id,
          where:
            ei.account_id == ^account_id_bytes and
              ei.issuer == ^issuer and
              ei.idp_id == ^idp_id and
              is_nil(a.disabled_at),
          select: %{actor_id: ei.actor_id},
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
            id: fragment("uuid_generate_v4()"),
            account_id: ^account_id_bytes,
            issuer: ^issuer,
            idp_id: ^idp_id,
            actor_id: fragment("COALESCE(?.id, ?.actor_id)", al, ei),
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

      {count, rows} =
        Safe.insert_all(
          Safe.unscoped(),
          ExternalIdentity,
          query_with_ctes,
          on_conflict: {:replace, replace_fields},
          conflict_target: [:account_id, :idp_id, :issuer],
          returning: true
        )

      case {count, rows} do
        {0, _} ->
          # Neither actor_lookup nor existing_identity matched → no identity
          {:error, :actor_not_found}

        {_, [%ExternalIdentity{} = identity]} ->
          # actor and account are long-lived records, safe to read from replica
          {:ok, Safe.preload(identity, [:actor, :account], :replica)}
      end
    end
  end
end
