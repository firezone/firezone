defmodule FzHttpWeb.AuthController do
  @moduledoc """
  Implements the CRUD for a Session
  """
  use FzHttpWeb, :controller
  require Logger

  alias FzHttpWeb.Authentication
  alias FzHttpWeb.Router.Helpers, as: Routes
  alias FzHttpWeb.UserFromAuth

  # Uncomment when Helpers.callback_url/1 is fixed
  # alias Ueberauth.Strategy.Helpers

  plug Ueberauth

  def request(conn, _params) do
    # XXX: Helpers.callback_url/1 generates the wrong URL behind nginx.
    # This is a bug in Ueberauth. auth_url is used instead.
    url = Routes.auth_url(conn, :callback, :identity)

    conn
    |> render("request.html", callback_url: url)
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
        conn
        |> configure_session(renew: true)
        |> put_session(:live_socket_id, "users_socket:#{user.id}")
        |> Authentication.sign_in(user, auth)
        |> redirect(to: root_path_for_role(conn, user.role))

      {:error, reason} ->
        conn
        |> put_flash(:error, "Error signing in: #{reason}")
        |> request(%{})
    end
  end

  def callback(conn, params) do
    %{"provider" => provider} = params

    with {:ok, tokens} <- OpenIDConnect.fetch_tokens(provider, params),
         {:ok, claims} <- OpenIDConnect.verify(provider, tokens["id_token"]) do
      case UserFromAuth.find_or_create(provider, claims) do
        {:ok, user} ->
          conn
          |> configure_session(renew: true)
          |> put_session(:live_socket_id, "users_socket:#{user.id}")
          |> Authentication.sign_in(user, %{provider: provider})
          |> redirect(to: root_path_for_role(conn, user.role))

        {:error, reason} ->
          conn
          |> put_flash(:error, "Error signing in: #{reason}")
          |> request(%{})
      end
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  def delete(conn, _params) do
    conn
    |> Authentication.sign_out()
    |> put_flash(:info, "You are now signed out.")
    |> redirect(to: Routes.root_path(conn, :index))
  end
end
