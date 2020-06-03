defmodule FgHttpWeb.Plugs.RedirectAuthenticated do
  @moduledoc """
  Redirects users when he/she tries to access an open resource while authenticated.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(default), do: default

  def call(conn, _default) do
    if get_session(conn, :email) do
      conn
      |> redirect(to: "/")
      |> halt()
    else
      conn
      |> assign(:session, nil)
    end
  end
end
