defmodule FzHttpWeb.Plug.Authorization do
  @moduledoc """
  Plug to ensure user has a specific role.
  This should be called after the resource is loaded into
  the connection with Guardian.
  """

  use FzHttpWeb, :controller

  alias FzHttp.Users.User
  alias FzHttpWeb.Auth.HTML.Authentication

  @not_authorized "Not authorized."

  def init(opts), do: opts

  def call(conn, :test) do
    conn
  end

  def call(conn, role), do: require_user_with_role(conn, role)

  def require_user_with_role(conn, role) do
    with %User{} = user <- Authentication.get_current_user(conn),
         ^role <- user.role do
      conn
    else
      _ ->
        conn
        |> Authentication.sign_out()
        |> put_flash(:error, @not_authorized)
        |> redirect(to: ~p"/")
        |> halt()
    end
  end
end
