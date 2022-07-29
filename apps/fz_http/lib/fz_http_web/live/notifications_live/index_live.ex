defmodule FzHttpWeb.NotificationsLive.Index do
  @moduledoc """
  Real time notifications received from the server.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Notifications
  alias Phoenix.PubSub

  require Logger

  @topic "notifications_live"

  def topic, do: @topic

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    PubSub.subscribe(FzHttp.PubSub, topic())

    {:ok,
     socket
     |> assign(:notifications, Notifications.current())
     |> assign(:page_title, "Notifications")}
  end

  @impl Phoenix.LiveView
  def handle_info({:notifications, notifications}, socket) do
    {:noreply,
     socket
     |> assign(notifications: notifications)}
  end
end
