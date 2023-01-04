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
    msg = Enum.map_join(errors, ". ", fn error -> error.message end)

    conn
    |> put_flash(:error, msg)
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case UserFromAuth.find_or_create(auth) do
      {:ok, user} ->
        maybe_sign_in(conn, user, auth)

      {:error, reason} when reason in [:not_found, :invalid_credentials] ->
        conn
        |> put_flash(
          :error,
          "Error signing in: user credentials are invalid or user does not exist"
        )
        |> request(%{})

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

  def callback(conn, %{"provider" => provider_id, "state" => state} = params)
      when is_binary(provider_id) do
    token_params = Map.merge(params, PKCE.token_params(conn))

    with :ok <- State.verify_state(conn, state),
         {:ok, tokens} <- openid_connect().fetch_tokens(provider_id, token_params),
         {:ok, claims} <- openid_connect().verify(provider_id, tokens["id_token"]) do
      case UserFromAuth.find_or_create(provider_id, claims) do
        {:ok, user} ->
          # only first-time connect will include refresh token
          # XXX: Remove this when SCIM 2.0 is implemented
          with %{"refresh_token" => refresh_token} <- tokens do
            FzHttp.OIDC.create_connection(user.id, provider_id, refresh_token)
          end

          conn
          |> put_session("id_token", tokens["id_token"])
          |> maybe_sign_in(user, %{provider: provider_id})

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

  # This can be called if the user attempts to visit one of the callback redirect URLs
  # directly.
  def callback(conn, params) do
    conn
    |> put_flash(:error, inspect(params) <> inspect(conn.assigns))
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    Authentication.sign_out(conn)
  end

  def reset_password(conn, _params) do
    render(conn, "reset_password.html")
  end

  def magic_link(conn, %{"email" => email}) do
    with {:ok, user} <- Users.fetch_user_by_email(email),
         {:ok, user} <- Users.request_sign_in_token(user) do
      FzHttpWeb.Mailer.AuthEmail.magic_link(user)
      |> FzHttpWeb.Mailer.deliver!()

      conn
      |> put_flash(:info, "Please check your inbox for the magic link.")
      |> redirect(to: ~p"/")
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:warning, "Failed to send magic link email.")
        |> redirect(to: ~p"/auth/reset_password")
    end
  end

  def magic_sign_in(conn, %{"user_id" => user_id, "token" => token}) do
    with {:ok, user} <- Users.fetch_user_by_id(user_id),
         {:ok, _user} <- Users.consume_sign_in_token(user, token) do
      maybe_sign_in(conn, user, %{provider: :magic_link})
    else
      {:error, _reason} ->
        conn
        |> put_flash(:error, "The magic link is not valid or has expired.")
        |> redirect(to: ~p"/")
    end
  end

  def redirect_oidc_auth_uri(conn, %{"provider" => provider_id}) when is_binary(provider_id) do
    verifier = PKCE.code_verifier()

    params = %{
      access_type: :offline,
      state: State.new(),
      code_challenge_method: PKCE.code_challenge_method(),
      code_challenge: PKCE.code_challenge(verifier)
    }

    uri = openid_connect().authorization_uri(provider_id, params)

    conn
    |> PKCE.put_cookie(verifier)
    |> State.put_cookie(params.state)
    |> redirect(external: uri)
  end

  defp maybe_sign_in(conn, user, %{provider: provider_key} = auth)
       when is_atom(provider_key) and provider_key in @local_auth_providers do
    if FzHttp.Configurations.get!(:local_auth_enabled) do
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
    |> redirect(to: root_path_for_user(user))
  end
end
