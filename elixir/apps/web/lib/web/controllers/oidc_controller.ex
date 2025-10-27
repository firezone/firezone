defmodule Web.OIDCController do
  use Web, :controller

  alias Domain.{
    Accounts,
    Actors,
    Auth,
    Entra,
    Google,
    Identities,
    Okta,
    OIDC,
    Tokens
  }

  alias Web.Session.Redirector

  require Logger

  # For persisting state across the IdP redirect
  @cookie_key "oidc"
  @cookie_options [
    sign: true,
    max_age: 30 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  # TODO: IDP REFACTOR
  # session length - matches session cookie max age
  @session_token_hours 8

  action_fallback Web.FallbackController

  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, provider} <- fetch_auth_provider(account, params) do
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
    |> delete_resp_cookie(@cookie_key)
    |> handle_error(:invalid_callback_params, params)
  end

  defp handle_authentication_callback(conn, state, code, params) do
    conn = fetch_cookies(conn, signed: [@cookie_key])
    context_type = context_type(params)

    with {:ok, cookie} <- Map.fetch(conn.cookies, @cookie_key),
         conn = delete_resp_cookie(conn, @cookie_key),
         true = Plug.Crypto.secure_compare(cookie["state"], state),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug(cookie["account_id"]),
         {:ok, provider} <- fetch_auth_provider(account, cookie),
         :ok <- validate_context(provider, context_type),
         {:ok, tokens} <-
           Web.OIDC.exchange_code(provider, code, cookie["verifier"]),
         {:ok, claims} <- Web.OIDC.verify_token(provider, tokens["id_token"]),
         userinfo = fetch_userinfo(provider, tokens["access_token"]),
         {:ok, identity} <- upsert_identity(account, provider, claims, userinfo),
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
    |> Plug.Conn.put_session(:verification_token, verification_token)
    |> Plug.Conn.put_session(:verification_code, code)
    |> redirect(to: ~p"/auth/oidc/verify")
  end

  defp provider_redirect(conn, account, provider, params) do
    with {:ok, uri, state, verifier} <- Web.OIDC.authorization_uri(provider) do
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
      |> put_resp_cookie(@cookie_key, cookie, @cookie_options)
      |> redirect(external: uri)
    end
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "google"} = params) do
    Google.fetch_auth_provider_by_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "okta"} = params) do
    Okta.fetch_auth_provider_by_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "entra"} = params) do
    Entra.fetch_auth_provider_by_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "oidc"} = params) do
    OIDC.fetch_auth_provider_by_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(_account, _params) do
    {:error, :invalid_provider}
  end

  defp fetch_userinfo(provider, access_token) do
    case Web.OIDC.fetch_userinfo(provider, access_token) do
      {:ok, userinfo} -> userinfo
      _ -> %{}
    end
  end

  # Entra
  defp upsert_identity(
         account,
         %Entra.AuthProvider{issuer: issuer},
         %{
           "iss" => issuer,
           "oid" => idp_id
         } = claims,
         userinfo
       ) do
    email = claims["email"]
    email_verified = claims["email_verified"] == true
    profile_attrs = extract_profile_attrs(claims, userinfo)

    Identities.upsert_identity_by_idp_fields(
      account,
      email,
      email_verified,
      issuer,
      idp_id,
      profile_attrs
    )
  end

  # Google
  defp upsert_identity(
         account,
         %Google.AuthProvider{issuer: issuer},
         %{
           "iss" => issuer,
           "sub" => idp_id
         } = claims,
         userinfo
       ) do
    email = claims["email"]
    email_verified = claims["email_verified"] == true
    profile_attrs = extract_profile_attrs(claims, userinfo)

    Identities.upsert_identity_by_idp_fields(
      account,
      email,
      email_verified,
      issuer,
      idp_id,
      profile_attrs
    )
  end

  # Okta
  defp upsert_identity(
         account,
         %Okta.AuthProvider{issuer: issuer},
         %{
           "iss" => issuer,
           "sub" => idp_id
         } = claims,
         userinfo
       ) do
    email = claims["email"]
    email_verified = claims["email_verified"] == true
    profile_attrs = extract_profile_attrs(claims, userinfo)

    Identities.upsert_identity_by_idp_fields(
      account,
      email,
      email_verified,
      issuer,
      idp_id,
      profile_attrs
    )
  end

  # Generic OIDC
  defp upsert_identity(
         account,
         %OIDC.AuthProvider{issuer: issuer},
         %{"iss" => issuer} = claims,
         userinfo
       ) do
    # Prefer "oid" claim (Microsoft Entra), fall back to "sub"
    idp_id = claims["oid"] || claims["sub"]

    if idp_id do
      email = claims["email"]
      email_verified = claims["email_verified"] == true
      profile_attrs = extract_profile_attrs(claims, userinfo)

      Identities.upsert_identity_by_idp_fields(
        account,
        email,
        email_verified,
        issuer,
        idp_id,
        profile_attrs
      )
    else
      {:error, :missing_identifier}
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

    attrs = %{
      type: context.type,
      secret_nonce: params["nonce"],
      secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      auth_provider_id: provider.id,
      identity_id: identity.id,
      expires_at: DateTime.add(DateTime.utc_now(), @session_token_hours, :hour),
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
    account_id = get_in(conn.cookies, [@cookie_key, "account_id"]) || ""
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
end
