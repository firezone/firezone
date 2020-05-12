defmodule FgHttpWeb.Plugs.Authenticator do
  @moduledoc """
  Loads the user's session from cookie
  """

  import Plug.Conn
  alias FgHttp.Users.User

  def init(default), do: default

  def call(conn, _default) do
    user = %User{id: 1, email: "dev_user@fireguard.network"}
    assign(conn, :current_user, user)
  end
end
