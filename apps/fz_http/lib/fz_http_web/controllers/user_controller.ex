defmodule FzHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """

  alias FzHttp.Users
  alias FzHttpWeb.Authentication
  use FzHttpWeb, :controller

  require Logger

  def delete(conn, _params) do
    user = Authentication.get_current_user(conn)

    with %{role: :admin} <- user do
      unless length(Users.list_admins()) > 1 do
        raise "Cannot delete one last admin"
      end
    end

    case Users.delete_user(user) do
      {:ok, _user} ->
        FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

      {:error, msg} ->
        Logger.error("Error deleting user: #{msg}")
    end

    Authentication.sign_out(conn)
  end
end
