defmodule FzHttpWeb.AuthorizationHelpers do
  @moduledoc """
  Authorization-related helpers
  """

  import Phoenix.LiveView
  alias FzHttpWeb.Router.Helpers, as: Routes

  def not_authorized(socket) do
    socket
    |> put_flash(:error, "Not authorized.")
    |> redirect(to: Routes.session_path(socket, :new))
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
