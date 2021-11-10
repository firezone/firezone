defmodule FzHttpWeb.ControllerHelpers do
  @moduledoc """
  Useful helpers for controllers
  """

  import Plug.Conn,
    only: [
      get_session: 2,
      put_resp_content_type: 2,
      send_resp: 3,
      halt: 1
    ]

  import Phoenix.Controller,
    only: [
      redirect: 2
    ]

  alias FzHttpWeb.Router.Helpers, as: Routes

  def redirect_unauthenticated(conn, _options) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> redirect(to: Routes.session_path(conn, :new))
        |> halt()

      _ ->
        conn
    end
  end

  def require_authenticated(conn, _options) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Forbidden")
        |> halt()

      _ ->
        conn
    end
  end
end
