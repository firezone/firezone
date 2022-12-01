defmodule FzHttpWeb.AuthController do
  @moduledoc """
  Implements the CRUD for a Session
  """
  use FzHttpWeb, :controller
  require Logger

  @local_auth_providers [:identity, :magic_link]

  alias FzHttp.Users
  alias FzHttpWeb.Auth.HTML.Authentication
  alias FzHttpWeb.OAuth.PKCE
  alias FzHttpWeb.OIDC.State
  alias FzHttpWeb.UserFromAuth

  import FzHttpWeb.OIDC.Helpers

  # Uncomment when Helpers.callback_url/1 is fixed
  # alias Ueberauth.Strategy.Helpers

  plug Ueberauth

  def request(conn, _params) do
    path = ~p"/auth/identity/callback"

    conn
    |> render("request.html", callback_path: path)
  end

  def callback(%{assigns: %{ueberauth_failure: %{errors: errors}}} = conn, _params) do
    msg =
      errors
      |> Enum.map_join(". ", fn error -> error.message end)

    conn
    |> put_flash(:error, msg)
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case UserFromAuth.find_or_create(auth) do
      {:ok, user} ->
        maybe_sign_in(conn, user, auth)

      {:error, reason} ->
        conn
        |> put_flash(:error, "Error signing in: #{reason}")
        |> request(%{})
    end
  end

  def callback(conn, %{"provider" => "saml"}) do
    key = {idp, _} = get_session(conn, "samly_assertion_key")
    assertion = %Samly.Assertion{} = Samly.State.get_assertion(conn, key)

    with {:ok, user} <-
           UserFromAuth.find_or_create(:saml, idp, %{"email" => assertion.subject.name}) do
      maybe_sign_in(conn, user, %{provider: idp})
    end
  end

  def callback(conn, %{"provider" => provider_key, "state" => state} = params) do
    token_params = Map.merge(params, PKCE.token_params(conn))

    with {:ok, provider} <- atomize_provider(provider_key),
         :ok <- State.verify_state(conn, state),
         {:ok, tokens} <- openid_connect().fetch_tokens(provider, token_params),
         {:ok, claims} <- openid_connect().verify(provider, tokens["id_token"]) do
      case UserFromAuth.find_or_create(provider_key, claims) do
        {:ok, user} ->
          # only first-time connect will include refresh token
          # XXX: Remove this when SCIM 2.0 is implemented
          with %{"refresh_token" => refresh_token} <- tokens do
            FzHttp.OIDC.create_connection(user.id, provider_key, refresh_token)
          end

          conn
          |> put_session("id_token", tokens["id_token"])
          |> maybe_sign_in(user, %{provider: provider})

        {:error, reason} ->
          conn
          |> put_flash(:error, "Error signing in: #{reason}")
          |> redirect(to: ~p"/")
      end
    else
      {:error, reason} ->
        msg = "OpenIDConnect Error: #{reason}"
        Logger.warn(msg)

        conn
        |> put_flash(:error, msg)
        |> redirect(to: ~p"/")

      # Error verifying claims or fetching tokens
      {:error, action, reason} ->
        Logger.warn("OpenIDConnect Error during #{action}: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed when performing this action: #{action}")
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    conn
    |> Authentication.sign_out()
  end

  def reset_password(conn, _params) do
    render(conn, "reset_password.html")
  end

  def magic_link(conn, %{"email" => email}) do
    case Users.reset_sign_in_token(email) do
      :ok ->
        conn
        |> put_flash(:info, "Please check your inbox for the magic link.")
        |> redirect(to: ~p"/")

      :error ->
        conn
        |> put_flash(:warning, "Failed to send magic link email.")
        |> redirect(to: ~p"/auth/reset_password")
    end
  end

  def magic_sign_in(conn, %{"token" => token}) do
    case Users.consume_sign_in_token(token) do
      {:ok, user} ->
        maybe_sign_in(conn, user, %{provider: :magic_link})

      {:error, _} ->
        conn
        |> put_flash(:error, "The magic link is not valid or has expired.")
        |> redirect(to: ~p"/")
    end
  end

  def redirect_oidc_auth_uri(conn, %{"provider" => provider_key}) do
    verifier = PKCE.code_verifier()

    params = %{
      access_type: :offline,
      state: State.new(),
      code_challenge_method: PKCE.code_challenge_method(),
      code_challenge: PKCE.code_challenge(verifier)
    }

    with {:ok, provider} <- atomize_provider(provider_key),
         uri <- openid_connect().authorization_uri(provider, params) do
      conn
      |> PKCE.put_cookie(verifier)
      |> State.put_cookie(params.state)
      |> redirect(external: uri)
    else
      _ ->
        msg = "OpenIDConnect error: provider #{provider_key} not found in config"
        Logger.warn(msg)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "OIDC Error. Check logs.")
        |> halt()
    end
  end

  defp maybe_sign_in(conn, user, %{provider: provider} = auth)
       when provider in @local_auth_providers do
    if Conf.get!(:local_auth_enabled) do
      do_sign_in(conn, user, auth)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "Local auth disabled")
      |> halt()
    end
  end

  defp maybe_sign_in(conn, user, auth), do: do_sign_in(conn, user, auth)

  defp do_sign_in(conn, user, auth) do
    conn
    |> Authentication.sign_in(user, auth)
    |> configure_session(renew: true)
    |> put_session(:live_socket_id, "users_socket:#{user.id}")
    |> redirect(to: root_path_for_role(user.role))
  end
end
