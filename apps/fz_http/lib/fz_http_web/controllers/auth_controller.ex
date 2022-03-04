defmodule FzHttpWeb.AuthController do
  @moduledoc """
  Implements the CRUD for a Session
  """
  use FzHttpWeb, :controller

  alias FzHttpWeb.Authentication
  alias FzHttpWeb.UserFromAuth
  alias Ueberauth.Strategy.Helpers

  plug Ueberauth

  def request(conn, _params) do
    conn
    |> render("request.html", callback_url: Helpers.callback_url(conn))
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
        |> put_session(:live_socket_id, "users_socket:#{user.id}")
        |> Authentication.sign_in(user, auth)
        |> configure_session(renew: true)
        |> redirect(to: root_path_for_role(conn, user.role))

      {:error, reason} ->
        conn
        |> put_flash(:error, "Error signing in: #{reason}")
        |> request(%{})
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "You are now signed out.")
    |> Authentication.sign_out()
    |> clear_session()
    |> redirect(to: Routes.root_path(conn, :index))
  end
end
