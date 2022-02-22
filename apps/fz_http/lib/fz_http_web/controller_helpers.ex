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

  alias FzHttp.Users
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

  def root_path_for_role(%Plug.Conn{} = conn) do
    user_id = get_session(conn, :user_id)

    if is_nil(user_id) do
      Routes.session_path(conn, :new)
    else
      user = Users.get_user(user_id)
      root_path_for_role(conn, user)
    end
  end

  def root_path_for_role(socket) do
    user = Map.get(socket.assigns, :current_user)

    if is_nil(user) do
      Routes.session_path(socket, :new)
    else
      root_path_for_role(socket, user)
    end
  end

  def root_path_for_role(conn_or_sock, nil) do
    Routes.session_path(conn_or_sock, :new)
  end

  def root_path_for_role(conn_or_sock, user) do
    case user.role do
      :unprivileged ->
        Routes.tunnel_unprivileged_index_path(conn_or_sock, :index)

      :admin ->
        Routes.user_index_path(conn_or_sock, :index)

      _ ->
        Routes.session_path(conn_or_sock, :new)
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
