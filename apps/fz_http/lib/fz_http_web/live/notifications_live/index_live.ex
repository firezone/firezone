defmodule FzHttpWeb.NotificationsLive.Index do
  @moduledoc """
  Real time notifications live view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Notifications
  alias Phoenix.PubSub

  require Logger

  @topic "notifications_live"
  @page_title "Notifications"
  @page_subtitle "Persisted notifications will appear below."

  def topic, do: @topic

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    PubSub.subscribe(FzHttp.PubSub, topic())

    {:ok,
     socket
     |> assign(:notifications, Notifications.current())
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  @impl Phoenix.LiveView
  def handle_info({:notifications, notifications}, socket) do
    {:noreply,
     socket
     |> assign(notifications: notifications)}
  end

  @impl Phoenix.LiveView
  def handle_event("clear_notification", %{"index" => index}, socket) do
    Notifications.clear_at(String.to_integer(index))
    {:noreply, socket}
  end

  defp icon(:error, assigns) do
    ~H"""
    <span class="icon has-text-danger">
      <i class="mdi mdi-24px mdi-alert-circle"></i>
    </span>
    """
  end
end
