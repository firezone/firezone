defmodule FgHttpWeb.Plugs.SessionLoader do
  @moduledoc """
  Loads the user's session from cookie
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  alias FgHttp.{Sessions, Users.Session}
  alias FgHttpWeb.Router.Helpers, as: Routes

  def init(default), do: default

  def call(conn, _default) do
    case get_session(conn, :user_id) do
      nil ->
        unauthed(conn)

      user_id ->
        case Sessions.get_session(user_id) do
          %Session{} = session ->
            conn
            |> assign(:session, session)

          _ ->
            unauthed(conn)
        end
    end
  end

  defp unauthed(conn) do
    conn
    |> clear_session()
    |> put_flash(:error, "Please sign in to access that page.")
    |> redirect(to: Routes.session_path(conn, :new))
    |> halt()
  end
end
