defmodule FzHttpWeb.NotificationsLive.Badge do
  @moduledoc """
  Notifications badge that shows the status of current notifications.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Notifications.Errors
  alias Phoenix.PubSub

  import FzHttpWeb.NotificationsLive.Index, only: [errors_topic: 0]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    PubSub.subscribe(FzHttp.PubSub, errors_topic())

    {:ok,
     socket
     |> assign(:count, length(Errors.current()))}
  end

  @impl Phoenix.LiveView
  def handle_info({:errors, errors}, socket) do
    {:noreply,
     socket
     |> assign(:count, length(errors))}
  end
end
