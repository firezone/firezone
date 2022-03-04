defmodule FzHttpWeb.SettingLive.Account do
  @moduledoc """
  Handles Account-related things.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:changeset, Users.change_user(socket.assigns.current_user))
     |> assign(:page_title, "Account Settings")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
