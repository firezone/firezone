defmodule Web.OIDCController do
  use Web, :controller

  alias Domain.{
    Accounts,
    Actors,
    AuthProviders,
    Auth,
    Tokens,
    Repo
  }

  alias Web.Session.Redirector

  require Logger

  # For persisting state across the IdP redirect
  @cookie_prefix "_oidc_"
  @cookie_options [
    sign: true,
    max_age: 30 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  action_fallback Web.FallbackController

  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         provider when not is_nil(provider) <- fetch_provider(account, params) do
      provider_redirect(conn, account, provider, params)
    else
      error -> handle_error(conn, error, params)
    end
  end

  def callback(conn, %{"state" => state, "code" => code} = params) do
    # Check if this is a verification operation (state starts with "oidc-verification:")
    case String.split(state, ":", parts: 2) do
      ["oidc-verification", verification_token] ->
        handle_verification_callback(conn, verification_token, code, params)

      _ ->
        handle_authentication_callback(conn, state, code, params)
    end
  end

  def callback(conn, params) do
    conn
    |> delete_resp_cookie(cookie_key(params["state"]))
    |> handle_error(:invalid_callback_params, params)
  end

  defp handle_authentication_callback(conn, state, code, params) do
    cookie_key = cookie_key(state)
    conn = fetch_cookies(conn, signed: [cookie_key])
    context_type = context_type(params)

    with {:ok, cookie} <- Map.fetch(conn.cookies, cookie_key),
         conn = delete_resp_cookie(conn, cookie_key),
         true = Plug.Crypto.secure_compare(cookie["state"], state),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug(cookie["account_id"]),
         provider when not is_nil(provider) <- fetch_provider(account, cookie),
         :ok <- validate_context(provider, context_type),
         {:ok, tokens} <-
           Web.OIDC.exchange_code(provider, code, cookie["verifier"]),
         {:ok, claims} <- Web.OIDC.verify_token(provider, tokens["id_token"]),
         userinfo = fetch_userinfo(provider, tokens["access_token"]),
         {:ok, identity} <- upsert_identity(account, claims, userinfo),
         :ok <- check_admin(identity, context_type),
         {:ok, token} <- create_token(conn, identity, provider, cookie["params"]) do
      signed_in(
        conn,
        context_type,
        account,
        identity,
        token,
        provider,
        tokens,
        cookie["params"]
      )
    else
      error -> handle_error(conn, error, params)
    end
  end

  defp handle_verification_callback(conn, verification_token, code, _params) do
    # Store verification info in session for the LiveView to pick up
    conn
    |> put_session(:verification_token, verification_token)
    |> put_session(:verification_code, code)
    |> redirect(to: ~p"/verification")
  end

  defp provider_redirect(conn, account, provider, params) do
    opts = [additional_params: %{prompt: "select_account"}]

    with {:ok, uri, state, verifier} <- Web.OIDC.authorization_uri(provider, opts) do
      cookie =
        %{
          "auth_provider_type" => params["auth_provider_type"],
          "auth_provider_id" => params["auth_provider_id"],
          "account_id" => account.id,
          "state" => state,
          "verifier" => verifier,
          "params" => sanitize(params)
        }

      conn
      |> put_resp_cookie(cookie_key(state), cookie, @cookie_options)
      |> redirect(external: uri)
    end
  end

  defp fetch_provider(
         account,
         %{"auth_provider_type" => type, "auth_provider_id" => id}
       ) do
    account_id = account.id
    schema = AuthProviders.AuthProvider.module!(type)

    import Ecto.Query

    from(p in schema,
      where: p.account_id == ^account_id and p.id == ^id and p.is_disabled == false
    )
    |> Repo.one()
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

  # Entra
  defp upsert_identity(account, claims, userinfo) do
    email = claims["email"]
    idp_id = claims["oid"] || claims["sub"]
    issuer = claims["iss"]
    email_verified = claims["email_verified"] == true
    profile_attrs = extract_profile_attrs(claims, userinfo)

    # Validate attributes first
    attrs =
      profile_attrs
      |> Map.put("account_id", account.id)
      |> Map.put("issuer", issuer)
      |> Map.put("idp_id", idp_id)

    with %{valid?: true} <- validate_upsert_attrs(attrs) do
      upsert_identity_query(account.id, email, email_verified, issuer, idp_id, profile_attrs)
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
      email
    ]a

    %Auth.Identity{}
    |> cast(attrs, idp_fields ++ ~w[account_id actor_id]a)
    |> validate_required(~w[issuer idp_id name account_id]a)
    |> Auth.Identity.Changeset.changeset()
  end

  defp upsert_identity_query(account_id, email, email_verified, issuer, idp_id, profile_attrs) do
    profile_fields =
      ~w[name given_name family_name middle_name nickname preferred_username profile picture]

    profile_values = Enum.map(profile_fields, &Map.get(profile_attrs, &1))
    update_set = Enum.map_join(profile_fields, ", ", &"#{&1} = EXCLUDED.#{&1}")
    insert_fields = Enum.join(profile_fields, ", ")
    value_placeholders = Enum.map_join(6..(5 + length(profile_fields)), ", ", &"$#{&1}")

    query = """
    WITH actor_lookup AS (
      SELECT id FROM actors
      WHERE account_id = $1 AND email = $2 AND disabled_at IS NULL AND $3 = true
      LIMIT 1
    ),
    existing_identity AS (
      SELECT ai.actor_id
      FROM auth_identities ai
      JOIN actors a ON a.id = ai.actor_id
      WHERE ai.account_id = $1 AND ai.issuer = $4 AND ai.idp_id = $5
        AND a.disabled_at IS NULL
      LIMIT 1
    )
    INSERT INTO auth_identities (
      id, account_id, issuer, idp_id, actor_id,
      #{insert_fields},
      inserted_at, created_by, created_by_subject
    )
    SELECT uuid_generate_v4(), $1, $4, $5,
           COALESCE(actor_lookup.id, existing_identity.actor_id),
           #{value_placeholders}, $14, $15,
           jsonb_build_object('name', 'System', 'email', null)
    FROM (SELECT 1) AS dummy
    LEFT JOIN actor_lookup ON true
    LEFT JOIN existing_identity ON true
    WHERE actor_lookup.id IS NOT NULL OR existing_identity.actor_id IS NOT NULL
    ON CONFLICT (account_id, issuer, idp_id) WHERE issuer IS NOT NULL OR idp_id IS NOT NULL
    DO UPDATE SET #{update_set}
    RETURNING *
    """

    params =
      [Ecto.UUID.dump!(account_id), email, email_verified, issuer, idp_id] ++
        profile_values ++ [DateTime.utc_now(), "system"]

    case Repo.query(query, params) do
      {:ok, %{rows: [row], columns: cols}} ->
        identity = Repo.load(Auth.Identity, {cols, row})
        {:ok, Repo.preload(identity, [:actor, :account])}

      {:ok, %{rows: []}} ->
        {:error, :actor_not_found}

      {:error, _} = error ->
        error
    end
  end

  defp extract_profile_attrs(claims, userinfo) do
    Map.merge(claims, userinfo)
    |> Map.take([
      "name",
      "given_name",
      "family_name",
      "middle_name",
      "nickname",
      "preferred_username",
      "profile",
      "picture"
    ])
  end

  defp check_admin(
         %Auth.Identity{actor: %Actors.Actor{type: :account_admin_user}},
         _context_type
       ),
       do: :ok

  defp check_admin(%Auth.Identity{actor: %Actors.Actor{type: :account_user}}, :client),
    do: :ok

  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

  defp validate_context(%{context: context}, :client)
       when context in [:clients_only, :clients_and_portal] do
    :ok
  end

  defp validate_context(%{context: context}, :browser)
       when context in [:portal_only, :clients_and_portal] do
    :ok
  end

  defp validate_context(_provider, _context_type), do: {:error, :invalid_context}

  defp create_token(conn, identity, provider, params) do
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

        :browser ->
          provider.portal_session_lifetime_secs || schema.default_portal_session_lifetime_secs()
      end

    attrs = %{
      type: context.type,
      secret_nonce: params["nonce"],
      secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      auth_provider_id: provider.id,
      identity_id: identity.id,
      expires_at: DateTime.add(DateTime.utc_now(), session_lifetime_secs, :second),
      created_by_user_agent: context.user_agent,
      created_by_remote_ip: context.remote_ip
    }

    with {:ok, token} <- Tokens.create_token(attrs) do
      {:ok, Tokens.encode_fragment!(token)}
    end
  end

  # Context: :browser
  # Store session cookie and redirect to portal or redirect_to parameter
  defp signed_in(conn, :browser, account, _identity, token, _provider, _tokens, params) do
    conn
    |> Web.Session.Cookie.put_account_cookie(account.id, token)
    |> Redirector.portal_signed_in(account, params)
  end

  # Context: :client
  # Store a cookie and redirect to client handler which redirects to the final URL based on platform
  defp signed_in(conn, :client, _account, identity, token, _provider, _tokens, params) do
    Redirector.client_signed_in(
      conn,
      identity.actor.name,
      identity.provider_identifier,
      token,
      params["state"]
    )
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser

  defp handle_error(conn, {:error, :not_admin}, params) do
    error = "This action requires admin privileges."
    path = ~p"/#{params["account_id_or_slug"]}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.warning("OIDC sign-in error: #{inspect(error)}")
    account_id = get_in(conn.cookies, [cookie_key(params["state"]), "account_id"]) || ""
    error = "An unexpected error occurred while signing you in. Please try again."
    path = ~p"/#{account_id}?#{sanitize(params)}"

    redirect_for_error(conn, error, path)
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

  defp cookie_key(state), do: @cookie_prefix <> state
end
