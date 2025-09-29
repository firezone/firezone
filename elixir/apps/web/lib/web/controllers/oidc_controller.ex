defmodule Web.OIDCController do
  use Web, :controller

  alias Domain.{
    Accounts,
    Auth,
    Google,
    Tokens
  }

  require Logger

  # For persisting state across the IdP redirect
  @cookie_key "oidc"
  @cookie_options [
    sign: true,
    max_age: 5 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  # For persisting state to hand off to the client
  @client_cookie_key "client"
  @client_cookie_options [
    sign: true,
    max_age: 2 * 60,
    same_site: "Strict",
    secure: true,
    http_only: true
  ]

  @recent_sessions 6

  action_fallback Web.FallbackController

  def sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
         {:ok, provider} <- fetch_provider(account, params["provider"]),
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
         true = Plug.Crypto.secure_compare(cookie.state, state),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug(cookie.account_id),
         {:ok, provider} <- fetch_provider(account, cookie.provider),
         {:ok, config} <- fetch_config(provider),
         {:ok, tokens} <- fetch_tokens(config, code, cookie.verifier),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]),
         {:ok, identity} <- fetch_identity(account, cookie.provider, claims["sub"]),
         :ok <- check_admin(identity, context_type(cookie.params)),
         {:ok, token} <- create_token(conn, identity, cookie.params, claims["nonce"]) do
      signed_in(conn, context_type(cookie.params), account, identity, token, cookie)
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
      cookie = %{
        account_id: account.id,
        provider: params["provider"],
        params: sanitize(params),
        state: state,
        verifier: verifier
      }

      conn =
        conn
        |> put_resp_cookie(@cookie_key, cookie, @cookie_options)
        |> redirect(external: uri)

      {:ok, conn}
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

  defp fetch_provider(account, "google") do
    Google.fetch_oidc_provider_for_account(account)
  end

  defp fetch_provider(_account, _provider) do
    {:error, :invalid_provider}
  end

  defp fetch_config(struct) do
    with {:ok, config} <- Application.fetch_env(:domain, struct.__struct__) do
      {:ok, Enum.into(config, %{})}
    end
  end

  defp fetch_identity(account, provider, sub) do
    Domain.Auth.fetch_identity_for_sign_in(account, provider, sub)
  end

  defp check_admin(%Auth.Identity{actor: %{role: :account_admin_user}}, _context_type), do: :ok
  defp check_admin(%Auth.Identity{actor: %{role: :account_user}}, :client), do: :ok
  defp check_admin(_identity, _context_type), do: {:error, :not_admin}

  defp create_token(conn, identity, params, nonce) do
    # TODO: IdP sync
    # This will use the default session duration in Domain.Auth which needs to be extended
    # for browser sessions to fix some UX issues. See https://github.com/firezone/firezone/issues/6789
    expires_at = nil
    context = Web.Auth.get_auth_context(conn, context_type(params))

    with {:ok, token} <- Domain.Auth.create_token(identity, context, nonce, expires_at) do
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
      state: cookie.state
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
    redirect_to = sanitize_redirect_to(params["redirect_to"], account)
    session = {:browser, account.id, token}

    sessions =
      get_session(conn, :sessions, [])
      |> then(&[session | &1])
      |> Enum.uniq_by(fn {context, account_id, _token} -> {context, account_id} end)
      |> Enum.take(@recent_sessions)

    conn
    |> put_session(:sessions, sessions)
    |> redirect(to: redirect_to)
  end

  # TODO: Is this needed? Shouldn't the router / plug pipeline already handle this?
  defp sanitize_redirect_to(nil, account), do: ~p"/#{account}/sites"
  defp sanitize_redirect_to("", account), do: ~p"/#{account}/sites"

  defp sanitize_redirect_to(to, account) do
    if String.starts_with?(to, "/#{account.slug}") or String.starts_with?(to, "/#{account.id}") do
      to
    else
      ~p"/#{account}/sites"
    end
  end

  # defp config(%Entra.OIDCProvider{}) do
  #   Application.fetch_env!(:domain, Domain.Entra.OIDCProvider)
  # end
  #
  # defp config(%Okta.OIDCProvider{} = provider) do
  #   Application.fetch_env!(:domain, Domain.Okta.OIDCProvider)
  #   |> Keyword.put(:client_id, provider.client_id)
  #   |> Keyword.put(:client_secret, provider.client_secret)
  # end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser

  defp handle_error(conn, {:error, :not_admin}, params) do
    error = "This action requires admin privileges."
    path = ~p"/#{params["account_id"]}"

    redirect_for_error(conn, error, path)
  end

  defp handle_error(conn, error, params) do
    Logger.warning("Failed to sign in", error: inspect(error))
    error = "An unexpected error occurred while signing you in. Please try again."
    path = ~p"/?#{sanitize(params)}"

    redirect_for_error(conn, error, path)
  end

  defp redirect_for_error(conn, error, path) do
    conn
    |> delete_resp_cookie(@cookie_key)
    |> put_flash(:error, error)
    |> redirect(to: path)
    |> halt()
  end

  defp sanitize(params), do: Web.Auth.take_sign_in_params(params)
  defp callback_url, do: url(~p"/auth/oidc/callback")
end
