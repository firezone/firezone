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

  # For persisting state to hand off to the client
  @client_cookie_key "client"
  @client_cookie_options [
    sign: true,
    max_age: 30 * 60,
    same_site: "Strict",
    secure: true,
    http_only: true
  ]

  @session_duration_hours 10

  @recent_sessions 6

  action_fallback Web.FallbackController

  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, provider} <- fetch_auth_provider(account, params),
         {:ok, config} <- fetch_config(provider) do
      provider_redirect(conn, account, config, params)
    else
      error -> handle_error(conn, error, params)
    end
  end

  def callback(conn, %{"state" => state, "code" => code} = params) do
    conn = fetch_cookies(conn, signed: [@cookie_key])

    with {:ok, cookie} <- Map.fetch(conn.cookies, @cookie_key),
         conn = delete_resp_cookie(conn, @cookie_key),
         true = Plug.Crypto.secure_compare(cookie["state"], state),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug(cookie["account_id"]),
         {:ok, provider} <- fetch_auth_provider(account, cookie),
         :ok <- validate_context(provider, context_type(cookie["params"])),
         {:ok, config} <- fetch_config(provider),
         {:ok, tokens} <- fetch_tokens(config, code, cookie["verifier"]),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]),
         {:ok, identity} <- fetch_identity(account, provider.directory_id, claims),
         :ok <- check_admin(identity, context_type(cookie["params"])),
         {:ok, token} <- create_token(conn, identity, cookie["params"]) do
      signed_in(conn, context_type(cookie["params"]), account, identity, token, cookie["params"])
    else
      error -> handle_error(conn, error, params)
    end
  end

  def callback(conn, params) do
    conn
    |> delete_resp_cookie(@cookie_key)
    |> handle_error(:invalid_callback_params, params)
  end

  defp provider_redirect(conn, account, config, params) do
    with {:ok, uri, {state, verifier}} <- build_redirect_uri(config) do
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

  defp build_redirect_uri(config) do
    state = Domain.Crypto.random_token(32)
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    oidc_params = %{state: state, code_challenge_method: :S256, code_challenge: challenge}

    with {:ok, uri} <- OpenIDConnect.authorization_uri(config, callback_url(), oidc_params) do
      {:ok, uri, {state, verifier}}
    end
  end

  defp fetch_tokens(config, code, verifier) do
    params = %{
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: callback_url()
    }

    OpenIDConnect.fetch_tokens(config, params)
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "google"} = params) do
    Google.fetch_auth_provider_by_auth_provider_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "okta"} = params) do
    Okta.fetch_auth_provider_by_auth_provider_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "entra"} = params) do
    Entra.fetch_auth_provider_by_auth_provider_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(account, %{"auth_provider_type" => "oidc"} = params) do
    OIDC.fetch_auth_provider_by_auth_provider_id(account, params["auth_provider_id"])
  end

  defp fetch_auth_provider(_account, _params) do
    {:error, :invalid_provider}
  end

  defp fetch_config(%Google.AuthProvider{}) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Google.AuthProvider) do
      config = Enum.into(config, %{redirect_uri: callback_url()})

      {:ok, config}
    end
  end

  defp fetch_config(%Okta.AuthProvider{} = provider) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Okta.AuthProvider) do
      discovery_document_uri = "https://#{provider.org_domain}/.well-known/openid-configuration"

      config =
        Enum.into(config, %{
          redirect_uri: callback_url(),
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          discovery_document_uri: discovery_document_uri
        })

      {:ok, config}
    end
  end

  defp fetch_config(%Entra.AuthProvider{} = provider) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Entra.AuthProvider) do
      discovery_document_uri =
        "https://login.microsoftonline.com/#{provider.tenant_id}/v2.0/.well-known/openid-configuration"

      config =
        Enum.into(config, %{
          redirect_uri: callback_url(),
          discovery_document_uri: discovery_document_uri
        })

      {:ok, config}
    end
  end

  defp fetch_config(%OIDC.AuthProvider{} = provider) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.OIDC.AuthProvider) do
      config =
        Enum.into(config, %{
          redirect_uri: callback_url(),
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          discovery_document_uri: provider.discovery_document_uri
        })

      {:ok, config}
    end
  end

  defp fetch_config(_provider) do
    {:error, :invalid_provider}
  end

  # Entra
  defp fetch_identity(
         account,
         %Entra.AuthProvider{
           issuer: issuer,
           tenant_id: idp_tenant
         },
         %{
           "iss" => issuer,
           "oid" => idp_id,
           "tid" => idp_tenant
         }
       ) do
    Identities.fetch_identity_by_idp_fields(account, issuer, idp_tenant, idp_id)
  end

  # Google
  defp fetch_identity(
         account,
         %Google.AuthProvider{
           issuer: issuer,
           hosted_domain: idp_tenant
         },
         %{
           "iss" => issuer,
           "sub" => idp_id,
           "hd" => idp_tenant
         }
       ) do
    Identities.fetch_identity_by_idp_fields(account, issuer, idp_tenant, idp_id)
  end

  # Okta
  defp fetch_identity(
         account,
         %Okta.AuthProvider{
           issuer: issuer,
           org_domain: idp_tenant
         },
         %{
           "iss" => "https://" <> idp_tenant <> "/oauth2/" <> _rest = issuer,
           "sub" => idp_id
         }
       ) do
    Identities.fetch_identity_by_idp_fields(account, issuer, idp_tenant, idp_id)
  end

  # Generic OIDC
  defp fetch_identity(
         account,
         %OIDC.AuthProvider{issuer: issuer},
         %{
           "iss" => issuer,
           "sub" => idp_id
         }
       ) do
    Identities.fetch_identity_by_idp_fields(account, issuer, nil, idp_id)
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

  defp create_token(conn, identity, params) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    type = context_type(params)
    headers = conn.req_headers
    context = Domain.Auth.get_auth_context(remote_ip, user_agent, headers, type)

    attrs = %{
      type: context.type,
      secret_nonce: params["nonce"],
      secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      identity_id: identity.id,
      # TODO: IdP refactor
      # session length
      expires_at: DateTime.add(DateTime.utc_now(), @session_duration_hours, :hour),
      created_by_user_agent: context.user_agent,
      created_by_remote_ip: context.remote_ip
    }

    with {:ok, token} <- Tokens.create_token(attrs) do
      {:ok, Tokens.encode_fragment!(token)}
    end
  end

  # Context: :client
  # 1. Store a cookie to be loaded in the client final redirect
  # 2. Redirect to client handler which reads the cookie and redirects to the final URL based on platform
  defp signed_in(conn, :client, account, identity, token, cookie) do
    redirect_url = ~p"/#{account.slug}/sign_in/client_redirect"

    client_cookie = %{
      actor_name: identity.actor.name,
      fragment: token,
      identity_provider_identifier: identity.provider_identifier,
      state: cookie["state"]
    }

    conn
    |> put_resp_cookie(@client_cookie_key, client_cookie, @client_cookie_options)
    |> put_root_layout(false)
    |> put_view(Web.SignInView)
    |> render("client_redirect.html", redirect_url: redirect_url, layout: false)
  end

  # Context: :browser
  # 1. Store session into session list
  # 2. Redirect to sanitized redirect_to param if present
  defp signed_in(conn, :browser, account, _identity, token, params) do
    session = {:browser, account.id, token}

    sessions =
      get_session(conn, :sessions, [])
      |> then(&[session | &1])
      |> Enum.uniq_by(fn {context, account_id, _token} -> {context, account_id} end)
      |> Enum.take(@recent_sessions)

    redirect_to = params["redirect_to"] || ~p"/#{account.slug}/sites"

    conn
    |> put_session(:sessions, sessions)
    |> redirect(to: redirect_to)
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser

  defp handle_error(conn, {:error, :not_admin}, params) do
    error = "This action requires admin privileges."
    path = ~p"/#{params["account_id_or_slug"]}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.warning("OIDC sign in error: #{inspect(error)}")
    Logger.warning("Failed to sign in", error: inspect(error))
    error = "An unexpected error occurred while signing you in. Please try again."
    path = ~p"/?#{sanitize(params)}"

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

  defp callback_url, do: url(~p"/auth/oidc/callback")
end
