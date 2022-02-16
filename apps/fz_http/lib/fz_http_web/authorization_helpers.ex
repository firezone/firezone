defmodule FzHttpWeb.AuthorizationHelpers do
  @moduledoc """
  Authorization-related helpers for live views and live components
  """

  import FzHttpWeb.ControllerHelpers, only: [root_path_for_role: 1]
  import Phoenix.LiveView

  def not_authorized(socket) do
    socket
    |> put_flash(:error, "Not authorized.")
    |> redirect(to: root_path_for_role(socket))
  end

  def has_role?(socket, role) do
    socket.assigns.current_user && socket.assigns.current_user.role == role
  end

  def authorize_role(socket, role) do
    if has_role?(socket, role) do
      {:cont, socket}
    else
      {:halt, not_authorized(socket)}
    end
  end
end
