defmodule Web.OIDCController do
  use Web, :controller

  alias Domain.{
    AuthProvider,
    Safe
  }

  alias __MODULE__.DB

  alias Web.Session.Redirector

  require Logger

  action_fallback Web.FallbackController

  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    with %Domain.Account{} = account <- DB.get_account_by_id_or_slug(account_id_or_slug),
         provider when not is_nil(provider) <- fetch_provider(account, params) do
      provider_redirect(conn, account, provider, params)
    else
      error -> handle_error(conn, error)
    end
  end

  def callback(conn, %{"state" => state, "code" => code}) do
    # Check if this is a verification operation (state starts with "oidc-verification:")
    case String.split(state, ":", parts: 2) do
      ["oidc-verification", verification_token] ->
        handle_verification_callback(conn, verification_token, code)

      _ ->
        handle_authentication_callback(conn, state, code)
    end
  end

  # Handle Entra admin consent callback (returns admin_consent & tenant instead of code)
  def callback(conn, %{"state" => state, "admin_consent" => _, "tenant" => _} = params) do
    case String.split(state, ":", parts: 2) do
      ["entra-verification", verification_token] ->
        handle_entra_verification_callback(conn, verification_token, params)

      ["entra-admin-consent", verification_token] ->
        handle_entra_verification_callback(conn, verification_token, params)

      _ ->
        handle_error(conn, :invalid_callback_params)
    end
  end

  def callback(conn) do
    conn
    |> Web.Cookie.OIDC.delete()
    |> handle_error(:invalid_callback_params)
  end

  defp handle_authentication_callback(conn, state, code) do
    with %Web.Cookie.OIDC{} = cookie <- Web.Cookie.OIDC.fetch(conn),
         conn = Web.Cookie.OIDC.delete(conn),
         true = Plug.Crypto.secure_compare(cookie.state, state),
         context_type = context_type(cookie.params),
         %Domain.Account{} = account <- DB.get_account_by_id_or_slug(cookie.account_id),
         provider when not is_nil(provider) <- fetch_provider(account, cookie),
         :ok <- validate_context(provider, context_type),
         {:ok, tokens} <-
           Web.OIDC.exchange_code(provider, code, cookie.verifier),
         {:ok, claims} <- Web.OIDC.verify_token(provider, tokens["id_token"]),
         userinfo = fetch_userinfo(provider, tokens["access_token"]),
         {:ok, identity} <- upsert_identity(account, claims, userinfo),
         :ok <- check_admin(identity, context_type),
         {:ok, session_or_token} <-
           create_session_or_token(conn, identity, provider, cookie.params) do
      signed_in(
        conn,
        context_type,
        account,
        identity,
        session_or_token,
        provider,
        tokens,
        cookie.params
      )
    else
      error -> handle_error(conn, error)
    end
  end

  defp handle_verification_callback(conn, verification_token, code) do
    # Store OIDC verification info in session for the LiveView to pick up
    conn
    |> put_session(:verification, %{
      "type" => "oidc",
      "token" => verification_token,
      "code" => code
    })
    |> redirect(to: ~p"/verification")
  end

  defp handle_entra_verification_callback(conn, verification_token, params) do
    # Determine Entra verification subtype from state prefix
    entra_type =
      case String.split(params["state"], ":", parts: 2) do
        ["entra-admin-consent", _] -> "directory_sync"
        ["entra-verification", _] -> "auth_provider"
        _ -> nil
      end

    # Store Entra admin consent info in session for the LiveView to pick up
    conn
    |> put_session(:verification, %{
      "type" => "entra",
      "entra_type" => entra_type,
      "token" => verification_token,
      "admin_consent" => params["admin_consent"],
      "tenant_id" => params["tenant"],
      "error" => params["error"],
      "error_description" => params["error_description"]
    })
    |> redirect(to: ~p"/verification")
  end

  defp provider_redirect(conn, account, provider, params) do
    opts = [additional_params: %{prompt: "select_account"}]

    with {:ok, uri, state, verifier} <- Web.OIDC.authorization_uri(provider, opts) do
      cookie = %Web.Cookie.OIDC{
        auth_provider_type: params["auth_provider_type"],
        auth_provider_id: params["auth_provider_id"],
        account_id: account.id,
        account_slug: account.slug,
        state: state,
        verifier: verifier,
        params: sanitize(params)
      }

      conn
      |> Web.Cookie.OIDC.put(cookie)
      |> redirect(external: uri)
    end
  end

  defp fetch_provider(account, %{"auth_provider_type" => type, "auth_provider_id" => id}) do
    DB.fetch_provider(account.id, type, id)
  end

  defp fetch_provider(account, %Web.Cookie.OIDC{} = cookie) do
    DB.fetch_provider(account.id, cookie.auth_provider_type, cookie.auth_provider_id)
  end

  defp fetch_provider(_account, _params) do
    {:error, :invalid_provider}
  end

  defp fetch_userinfo(provider, access_token) do
    case Web.OIDC.fetch_userinfo(provider, access_token) do
      {:ok, userinfo} -> userinfo
      _ -> %{}
    end
  end

  defp upsert_identity(account, claims, userinfo) do
    email = claims["email"]
    idp_id = claims["oid"] || claims["sub"]
    issuer = claims["iss"]
    email_verified = (claims["email_verified"] || userinfo["email_verified"]) == true
    profile_attrs = extract_profile_attrs(claims, userinfo)

    # In production, admins should hopefully ensure emails are verified.
    # If this does not occur regularly we might consider enforcing it in the future.
    unless email_verified do
      Logger.info("OIDC identity email not verified",
        account_id: account.id,
        account_slug: account.slug,
        issuer: issuer
      )
    end

    # Validate attributes first
    attrs =
      profile_attrs
      |> Map.put("account_id", account.id)
      |> Map.put("issuer", issuer)
      |> Map.put("idp_id", idp_id)

    with %{valid?: true} <- validate_upsert_attrs(attrs) do
      DB.upsert_identity(account.id, email, issuer, idp_id, profile_attrs)
    else
      changeset -> {:error, changeset}
    end
  end

  defp validate_upsert_attrs(attrs) do
    import Ecto.Changeset

    idp_fields = ~w[
      issuer
      idp_id
      name
      given_name
      family_name
      middle_name
      nickname
      preferred_username
      profile
      picture
    ]a

    %Domain.ExternalIdentity{}
    |> cast(attrs, idp_fields ++ ~w[account_id actor_id]a)
    |> validate_required(~w[issuer idp_id name account_id]a)
  end

  defp extract_profile_attrs(claims, userinfo) do
    Map.merge(claims, userinfo)
    |> Map.take([
      "email",
      "name",
      "given_name",
      "family_name",
      "middle_name",
      "nickname",
      "preferred_username",
      "profile",
      "picture"
    ])
    |> maybe_populate_name()
  end

  defp maybe_populate_name(attrs) do
    case attrs["name"] do
      nil -> Map.put(attrs, "name", attrs["given_name"] <> " " <> attrs["family_name"])
      "" -> Map.put(attrs, "name", attrs["given_name"] <> " " <> attrs["family_name"])
      _ -> attrs
    end
  end

  defp check_admin(
         %Domain.ExternalIdentity{actor: %Domain.Actor{type: :account_admin_user}},
         _context_type
       ),
       do: :ok

  defp check_admin(%Domain.ExternalIdentity{actor: %Domain.Actor{type: :account_user}}, :client),
    do: :ok

  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

  defp validate_context(%{context: context}, :client)
       when context in [:clients_only, :clients_and_portal] do
    :ok
  end

  defp validate_context(%{context: context}, :portal)
       when context in [:portal_only, :clients_and_portal] do
    :ok
  end

  defp validate_context(_provider, _context_type), do: {:error, :invalid_context}

  defp create_session_or_token(conn, identity, provider, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Domain.Auth.Context.build(remote_ip, user_agent, headers, type)

    # Get the provider schema module to access default values
    schema = provider.__struct__

    # Determine session lifetime based on context type
    session_lifetime_secs =
      case type do
        :client ->
          provider.client_session_lifetime_secs || schema.default_client_session_lifetime_secs()

        :portal ->
          provider.portal_session_lifetime_secs || schema.default_portal_session_lifetime_secs()
      end

    expires_at = DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second)

    case type do
      :portal ->
        Domain.Auth.create_portal_session(
          identity.account_id,
          identity.actor_id,
          provider.id,
          context,
          expires_at
        )

      :client ->
        attrs = %{
          secret_nonce: params["nonce"],
          account_id: identity.account_id,
          actor_id: identity.actor_id,
          auth_provider_id: provider.id,
          identity_id: identity.id,
          expires_at: expires_at
        }

        Domain.Auth.create_gui_client_token(attrs)
    end
  end

  # Context: :portal
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :portal, account, _identity, session, _provider, _tokens, params) do
    conn
    |> Web.Cookie.Session.put(account.id, %Web.Cookie.Session{session_id: session.id})
    |> Redirector.portal_signed_in(account, params)
  end

  # Context: :client
  # Store a cookie and redirect to client handler which redirects to the final URL based on platform
  defp signed_in(conn, :client, account, identity, token, _provider, _tokens, params) do
    Redirector.client_signed_in(
      conn,
      account,
      identity.actor.name,
      identity.email || identity.actor.email,
      token,
      params["state"]
    )
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :portal

  defp handle_error(conn, {:error, :not_admin}) do
    {account_slug, original_params} = fetch_error_context(conn)
    error = "This action requires admin privileges."
    path = ~p"/#{account_slug}?#{sanitize(original_params)}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :actor_not_found}) do
    {account_slug, original_params} = fetch_error_context(conn)
    error = "Unable to sign you in. Please contact your administrator."
    path = ~p"/#{account_slug}?#{sanitize(original_params)}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, {:error, :email_not_verified}) do
    {account_slug, original_params} = fetch_error_context(conn)
    error = "Your email address must be verified before signing in."
    path = ~p"/#{account_slug}?#{sanitize(original_params)}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error) do
    Logger.warning("OIDC sign-in error: #{inspect(error)}")
    {account_slug, original_params} = fetch_error_context(conn)
    error = "An unexpected error occurred while signing you in. Please try again."
    path = ~p"/#{account_slug}?#{sanitize(original_params)}"

    redirect_for_error(conn, error, path)
  end

  defp fetch_error_context(conn) do
    case Web.Cookie.OIDC.fetch(conn) do
      %Web.Cookie.OIDC{account_slug: slug, params: params} -> {slug, params || %{}}
      nil -> {"", %{}}
    end
  end

  defp redirect_for_error(conn, error, path) do
    conn
    |> put_flash(:error, error)
    |> redirect(to: path)
    |> halt()
  end

  defp sanitize(params) do
    Map.take(params, ["as", "redirect_to", "state", "nonce"])
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, AuthProvider, ExternalIdentity}
    alias Domain.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Domain.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped() |> Safe.one()
    end

    def fetch_provider(account_id, type, id) do
      schema = AuthProvider.module!(type)

      from(p in schema,
        where: p.account_id == ^account_id and p.id == ^id and p.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def upsert_identity(account_id, email, issuer, idp_id, %{} = profile_attrs) do
      now = DateTime.utc_now()

      profile_fields = [
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

      # Convert account_id to the DB (binary) format expected by uuid/binary_id columns
      account_id_db =
        case account_id do
          # already a 16-byte binary
          <<_::128>> -> account_id
          # string UUID -> dump to binary
          _ -> Ecto.UUID.dump!(account_id)
        end

      # Precompute profile values outside the query
      profile_values = %{
        email: Map.get(profile_attrs, "email"),
        name: Map.get(profile_attrs, "name"),
        given_name: Map.get(profile_attrs, "given_name"),
        family_name: Map.get(profile_attrs, "family_name"),
        middle_name: Map.get(profile_attrs, "middle_name"),
        nickname: Map.get(profile_attrs, "nickname"),
        preferred_username: Map.get(profile_attrs, "preferred_username"),
        profile: Map.get(profile_attrs, "profile"),
        picture: Map.get(profile_attrs, "picture")
      }

      actor_lookup_cte =
        from(a in "actors",
          where:
            a.account_id == ^account_id_db and
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
            ei.account_id == ^account_id_db and
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
            account_id: ^account_id_db,
            issuer: ^issuer,
            idp_id: ^idp_id,
            actor_id: fragment("COALESCE(?.id, ?.actor_id)", al, ei),
            email: ^profile_values.email,
            name: ^profile_values.name,
            given_name: ^profile_values.given_name,
            family_name: ^profile_values.family_name,
            middle_name: ^profile_values.middle_name,
            nickname: ^profile_values.nickname,
            preferred_username: ^profile_values.preferred_username,
            profile: ^profile_values.profile,
            picture: ^profile_values.picture,
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
          on_conflict: {:replace, profile_fields},
          conflict_target: [:account_id, :idp_id, :issuer],
          returning: true
        )

      case {count, rows} do
        {0, _} ->
          # Neither actor_lookup nor existing_identity matched → no identity
          {:error, :actor_not_found}

        {_, [%ExternalIdentity{} = identity]} ->
          {:ok, Safe.preload(identity, [:actor, :account])}
      end
    end
  end
end
