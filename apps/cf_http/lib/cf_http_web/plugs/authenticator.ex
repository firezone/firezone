defmodule CfHttpWeb.Plugs.Authenticator do
  @moduledoc """
  Loads the user's session from cookie
  """

  import Plug.Conn
  alias CfHttp.User

  def init(default), do: default

  def call(conn, _default) do
    user = %User{email: "dev_user@cloudfire.network"}
    assign(conn, :current_user, user)
  end
end
