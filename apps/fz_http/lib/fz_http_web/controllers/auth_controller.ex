defmodule FzHttpWeb.AuthController do
  @moduledoc """
  Implements the CRUD for a Session
  """
  use FzHttpWeb, :controller
  alias FzHttp.Users
  alias FzHttp.Auth
  alias FzHttpWeb.Auth.HTML.Authentication
  alias FzHttpWeb.OAuth.PKCE
  alias FzHttpWeb.OIDC.State
  alias FzHttpWeb.UserFromAuth
  require Logger

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
        do_sign_in(conn, user, auth)

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

  # This can be called if the user attempts to visit one of the callback redirect URLs
  # directly.
  def callback(conn, params) do
    conn
    |> put_flash(:error, inspect(params) <> inspect(conn.assigns))
    |> redirect(to: ~p"/")
  end

  def oidc_callback(conn, %{"provider" => provider_id, "state" => state} = params)
      when is_binary(provider_id) do
    token_params = Map.merge(params, PKCE.token_params(conn))

    with :ok <- State.verify_state(conn, state),
         {:ok, config} <- Auth.fetch_oidc_provider_config(provider_id),
         {:ok, tokens} <- OpenIDConnect.fetch_tokens(config, token_params),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]) do
      case UserFromAuth.find_or_create(provider_id, claims) do
        {:ok, user} ->
          # only first-time connect will include refresh token
          # XXX: Remove this when SCIM 2.0 is implemented
          with %{"refresh_token" => refresh_token} <- tokens do
            FzHttp.OIDC.create_connection(user.id, provider_id, refresh_token)
          end

          conn
          |> put_session("id_token", tokens["id_token"])
          |> do_sign_in(user, %{provider: provider_id})

        {:error, reason} ->
          conn
          |> put_flash(:error, "Error signing in: #{reason}")
          |> redirect(to: ~p"/")
      end
    else
      # Error verifying state, claims or fetching tokens
      {:error, error} ->
        msg = "An OpenIDConnect error occurred. Details: #{inspect(error)}"
        Logger.error(msg)

        conn
        |> put_flash(:error, msg)
        |> redirect(to: ~p"/")
    end
  end

  def saml_callback(conn, _params) do
    key = {idp, _} = get_session(conn, "samly_assertion_key")
    assertion = %Samly.Assertion{} = Samly.State.get_assertion(conn, key)

    with {:ok, user} <-
           UserFromAuth.find_or_create(:saml, idp, %{"email" => assertion.subject.name}) do
      do_sign_in(conn, user, %{provider: idp})
    else
      {:error, %{errors: [email: {"is invalid email address", _metadata}]}} ->
        conn
        |> put_flash(
          :error,
          "SAML provider did not return a valid email address in `name` assertion"
        )
        |> redirect(to: ~p"/")

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/")

      other ->
        other
    end
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
      do_sign_in(conn, user, %{provider: :magic_link})
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

    with {:ok, config} <- Auth.fetch_oidc_provider_config(provider_id),
         {:ok, uri} <- OpenIDConnect.authorization_uri(config, params) do
      conn
      |> PKCE.put_cookie(verifier)
      |> State.put_cookie(params.state)
      |> redirect(external: uri)
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Can not redirect user to OIDC auth uri", reason: inspect(reason))

        conn
        |> put_flash(:error, "Error while processing OpenID request.")
        |> redirect(to: ~p"/")
    end
  end

  defp do_sign_in(conn, user, auth) do
    conn
    |> Authentication.sign_in(user, auth)
    |> configure_session(renew: true)
    |> put_session(:live_socket_id, "users_socket:#{user.id}")
    |> redirect(to: root_path_for_user(user))
  end
end
