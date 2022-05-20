defmodule FzHttpWeb.UserLive.AllowedToConnectComponent do
  @moduledoc """
  Handles user form.
  """
  use FzHttpWeb, :live_component

  import Ecto.Changeset
  alias FzHttp.Repo

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <input type="checkbox" phx-target={@myself} disabled={@user.role == :admin}
        phx-click="toggle_allowed_to_connect" checked={@user.allowed_to_connect} />
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_allowed_to_connect", params, socket) do
    user =
      socket.assigns.user
      |> change()
      |> put_change(:allowed_to_connect, !!params["value"])
      |> Repo.update!()

    {:noreply, assign(socket, :user, user)}
  end
end
