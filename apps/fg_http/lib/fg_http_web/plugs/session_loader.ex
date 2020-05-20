defmodule FgHttpWeb.Plugs.SessionLoader do
  @moduledoc """
  Loads the user's session from cookie
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias FgHttp.Sessions
  alias FgHttpWeb.Router.Helpers, as: Routes

  def init(default), do: default

  def call(conn, _default) do
    case Sessions.load_session("blah session id") do
      {:ok, {session, user}} ->
        conn
        |> assign(:current_session, session)
        |> assign(:current_user, user)
        |> assign(:user_signed_in?, true)

      {:error, _} ->
        conn
        |> redirect(to: Routes.session_path(conn, :new))
        |> halt
    end
  end
end
