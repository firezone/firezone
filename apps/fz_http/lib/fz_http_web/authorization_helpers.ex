defmodule FzHttpWeb.AuthorizationHelpers do
  @moduledoc """
  Authorization-related helpers
  """
  use FzHttpWeb, :helper
  import Phoenix.LiveView

  def not_authorized(socket) do
    socket
    |> put_flash(:error, "Not authorized.")
    |> redirect(to: ~p"/")
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

  def authorize_role(socket, role) do
    if has_role?(socket, role) do
      {:cont, socket}
    else
      {:halt, not_authorized(socket)}
    end
  end
end
