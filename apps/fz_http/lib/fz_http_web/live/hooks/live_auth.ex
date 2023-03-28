defmodule FzHttpWeb.LiveAuth do
  @moduledoc """
  Handles loading default assigns and authorizing.
  """
  import Phoenix.Component
  import FzHttpWeb.AuthorizationHelpers
  alias FzHttpWeb.Auth.HTML.Authentication
  alias FzHttp.Auth
  require Logger

  def on_mount(role, _params, conn, socket) do
    case Authentication.get_current_subject(conn) do
      %Auth.Subject{actor: {:user, user}} = subject ->
        socket
        |> assign_new(:subject, fn -> subject end)
        |> assign_new(:current_user, fn -> user end)
        |> authorize_role(role)

      nil ->
        Logger.warn("Could not get_current_subject from session in LiveAuth.on_mount/4.")
        {:halt, not_authorized(socket)}
    end
  end

  def has_role?(_, :any) do
    true
  end

  def has_role?(%Phoenix.LiveView.Socket{} = socket, role) do
    socket.assigns.current_user && socket.assigns.current_user.role == role
  end

  def has_role?(%FzHttp.Users.User{} = user, role) do
    user.role == role
  end

  def has_role?(_, _) do
    false
  end

  defp authorize_role(socket, role) do
    if has_role?(socket, role) do
      {:cont, socket}
    else
      {:halt, not_authorized(socket)}
    end
  end
end
