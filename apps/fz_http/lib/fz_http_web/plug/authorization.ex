defmodule FzHttpWeb.Plug.Authorization do
  @moduledoc """
  Plug to ensure user has a specific role.
  This should be called after the resource is loaded into
  the connection with Guardian.
  """

  use FzHttpWeb, :controller

  import FzHttpWeb.ControllerHelpers, only: [root_path_for_role: 1]
  alias FzHttpWeb.Auth.WWW.Authentication

  @not_authorized "Not authorized."

  def init(opts), do: opts

  def call(conn, :test) do
    conn
  end

  def call(conn, role), do: require_user_with_role(conn, role)

  def require_user_with_role(conn, role) do
    user = Authentication.get_current_user(conn)

    if user.role == role do
      conn
    else
      conn
      |> put_flash(:error, @not_authorized)
      |> redirect(to: root_path_for_role(user.role))
      |> halt()
    end
  end
end
