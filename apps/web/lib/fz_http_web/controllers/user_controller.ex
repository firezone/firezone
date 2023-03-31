defmodule FzHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """
  use FzHttpWeb, :controller
  alias FzHttp.Users
  alias FzHttpWeb.Auth.HTML.Authentication
  require Logger

  def delete(conn, _params) do
    %{actor: {:user, user}} = subject = Authentication.get_current_subject(conn)

    case Users.delete_user(user, subject) do
      {:ok, _user} ->
        FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})
        Authentication.sign_out(conn)

      {:error, :cant_delete_the_last_admin} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FzHttpWeb.ErrorView)
        |> render("422.json", reason: "Can't delete the last admin user.")

      {:error, %Ecto.Changeset{errors: [id: {"is stale", _}]}} ->
        not_found(conn)

      {:error, {:unauthorized, _context}} ->
        not_found(conn)

      {:error, :unauthorized} ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(FzHttpWeb.ErrorView)
    |> render("404.json")
  end
end
