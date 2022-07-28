defmodule FzHttpWeb.NotificationsLive.Index do
  @moduledoc """
  Real time notifications received from the server.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Notifications.Errors
  alias Phoenix.PubSub

  require Logger

  @errors_topic "notifications_live_errors"

  def errors_topic, do: @errors_topic

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    PubSub.subscribe(FzHttp.PubSub, errors_topic())

    {:ok,
     socket
     |> assign(:errors, Errors.current())
     |> assign(:page_title, "Notifications")}
  end

  @impl Phoenix.LiveView
  def handle_info({:errors, errors}, socket) do
    {:noreply,
     socket
     |> assign(errors: errors)}
  end
end
