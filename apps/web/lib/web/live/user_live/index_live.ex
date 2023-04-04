defmodule Web.UserLive.Index do
  @moduledoc """
  Handles User LiveViews.
  """
  use Web, :live_view

  alias Domain.Users

  @page_title "Users"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, users} <- Users.list_users(socket.assigns.subject, hydrate: [:device_count]) do
      socket =
        socket
        |> assign(:users, users)
        |> assign(:changeset, Users.change_user())
        |> assign(:page_title, @page_title)

      {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
