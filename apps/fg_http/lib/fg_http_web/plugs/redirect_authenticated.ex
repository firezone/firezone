defmodule FgHttpWeb.Plugs.RedirectAuthenticated do
  @moduledoc """
  Redirects users when he/she tries to access an open resource while authenticated.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias FgHttpWeb.Router.Helpers, as: Routes

  def init(default), do: default

  def call(conn, _default) do
    if get_session(conn, :user_id) do
      conn
      |> redirect(to: Routes.device_path(conn, :index))
      |> halt()
    else
      conn
    end
  end
end
