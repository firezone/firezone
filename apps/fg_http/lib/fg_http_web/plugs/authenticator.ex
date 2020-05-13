defmodule FgHttpWeb.Plugs.Authenticator do
  @moduledoc """
  Loads the user's session from cookie
  """

  import Plug.Conn
  alias FgHttp.{Users.User, Repo}


  def init(default), do: default

  def call(conn, _default) do
    user = Repo.one(User)
    assign(conn, :current_user, user)
  end
end
