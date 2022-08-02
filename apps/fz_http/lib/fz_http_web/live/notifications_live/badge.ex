defmodule FzHttpWeb.NotificationsLive.Badge do
  @moduledoc """
  Notifications badge that shows the status of current notifications.
  """
  use FzHttpWeb, :live_view_without_layout

  alias FzHttpWeb.Router.Helpers, as: Routes
  alias FzHttp.Notifications
  alias Phoenix.PubSub

  import FzHttpWeb.NotificationsLive.Index, only: [topic: 0]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    PubSub.subscribe(FzHttp.PubSub, topic())

    {:ok,
     socket
     |> assign(:count, length(Notifications.current()))}
  end

  @impl Phoenix.LiveView
  def handle_info({:notifications, notifications}, socket) do
    {:noreply,
     socket
     |> assign(:count, length(notifications))}
  end
end
