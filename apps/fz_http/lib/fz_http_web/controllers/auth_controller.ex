defmodule FzHttpWeb.AuthController do
  @moduledoc """
  Implements the CRUD for a Session
  """
  use FzHttpWeb, :controller
  require Logger

  alias FzCommon.FzCrypto
  alias FzHttp.Users
  alias FzHttpWeb.Authentication
  alias FzHttpWeb.Router.Helpers, as: Routes
  alias FzHttpWeb.UserFromAuth

  # Uncomment when Helpers.callback_url/1 is fixed
  # alias Ueberauth.Strategy.Helpers

  plug Ueberauth

  def request(conn, _params) do
    # XXX: Helpers.callback_url/1 generates the wrong URL behind nginx.
    # This is a bug in Ueberauth. auth_path is used instead.
    path = Routes.auth_path(conn, :callback, :identity)

    conn
    |> render("request.html", callback_path: path)
  end

  def callback(%{assigns: %{ueberauth_failure: %{errors: errors}}} = conn, _params) do
    msg =
      errors
      |> Enum.map_join(". ", fn error -> error.message end)

    conn
    |> put_flash(:error, msg)
    |> redirect(to: Routes.root_path(conn, :index))
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

  def callback(conn, params) do
    %{"provider" => provider_key} = params
    openid_connect = Application.fetch_env!(:fz_http, :openid_connect)

    atomize = fn key ->
      try do
        {:ok, String.to_existing_atom(key)}
      catch
        ArgumentError -> {:error, "OIDC Provider not found"}
      end
    end

    with {:ok, provider} <- atomize.(provider_key),
         {:ok, tokens} <- openid_connect.fetch_tokens(provider, params),
         {:ok, claims} <- openid_connect.verify(provider, tokens["id_token"]) do
      case UserFromAuth.find_or_create(provider, claims) do
        {:ok, user} ->
          # only first-time connect will include refresh token
          with %{"refresh_token" => refresh_token} <- tokens do
            FzHttp.OIDC.create_connection(user.id, provider_key, refresh_token)
          end

          maybe_sign_in(conn, user, %{provider: provider})

        {:error, reason} ->
          conn
          |> put_flash(:error, "Error signing in: #{reason}")
          |> request(%{})
      end
    else
      {:error, reason} ->
        msg = "OpenIDConnect Error: #{reason}"
        Logger.warn(msg)

        conn
        |> put_flash(:error, msg)
        |> request(%{})

      # Error verifying claims or fetching tokens
      {:error, action, reason} ->
        Logger.warn("OpenIDConnect Error during #{action}: #{reason}")
        send_resp(conn, 401, "")
    end
  end

  def delete(conn, _params) do
    conn
    |> Authentication.sign_out()
    |> put_flash(:info, "You are now signed out.")
    |> redirect(to: Routes.root_path(conn, :index))
  end

  def reset_password(conn, _params) do
    render(conn, "reset_password.html")
  end

  def magic_link(conn, %{"email" => email}) do
    case Users.reset_sign_in_token(email) do
      :ok ->
        conn
        |> put_flash(:info, "Please check your inbox for the magic link.")
        |> redirect(to: Routes.root_path(conn, :index))

      :error ->
        conn
        |> put_flash(:warning, "Failed to send magic link email.")
        |> redirect(to: Routes.auth_path(conn, :reset_password))
    end
  end

  def magic_sign_in(conn, %{"token" => token}) do
    case Users.consume_sign_in_token(token) do
      {:ok, user} ->
        maybe_sign_in(conn, user, %{provider: :magic_link})

      {:error, _} ->
        conn
        |> put_flash(:error, "The magic link is not valid or has expired.")
        |> redirect(to: Routes.root_path(conn, :index))
    end
  end

  def redirect_oidc_auth_uri(conn, %{"provider" => provider}) do
    openid_connect = Application.fetch_env!(:fz_http, :openid_connect)

    params = %{
      state: FzCrypto.rand_string(),
      # needed for google
      access_type: "offline"
    }

    uri = openid_connect.authorization_uri(String.to_existing_atom(provider), params)

    conn
    |> redirect(external: uri)
  end

  defp maybe_sign_in(conn, user, %{provider: provider} = auth)
       when provider in [:identity, :magic_link] do
    if Application.fetch_env!(:fz_http, :local_auth_enabled) do
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
    |> configure_session(renew: true)
    |> Authentication.sign_in(user, auth)
    |> put_session(:live_socket_id, "users_socket:#{user.id}")
    |> redirect(to: root_path_for_role(conn, user.role))
  end
end
