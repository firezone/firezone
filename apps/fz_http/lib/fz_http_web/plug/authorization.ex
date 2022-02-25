defmodule FzHttpWeb.Plug.Authorization do
  @moduledoc """
  Plug to ensure user has a specific role.
  This should be called after the resource is loaded into
  the connection with Guardian.
  """

  import Plug.Conn, only: [halt: 1]
  import Phoenix.Controller
  import FzHttpWeb.ControllerHelpers, only: [root_path_for_role: 2]
  alias FzHttpWeb.Authentication

  @not_authorized "Not authorized to access this page"

  def init(opts), do: opts

  def call(conn, :admin) do
    require_user_with_role(conn, :admin)
  end

  def call(conn, :unprivileged) do
    require_user_with_role(conn, :unprivileged)
  end

  def call(conn, _opts) do
    not_authorized(conn)
  end

  def require_user_with_role(conn, role) do
    user = Authentication.get_current_user(conn)

    if user.role == role do
      conn
    else
      not_authorized(conn)
    end
  end

  def not_authorized(conn) do
    conn
    |> put_flash(:error, @not_authorized)
    |> redirect(to: not_authorized_path(conn))
    |> halt()
  end

  defp not_authorized_path(conn) do
    user = Authentication.get_current_user(conn)
    root_path_for_role(conn, user.role)
  end
end
