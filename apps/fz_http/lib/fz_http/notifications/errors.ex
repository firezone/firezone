defmodule FzHttp.Notifications.Errors do
  @moduledoc """
  Track error notification state for notifications live view.
  """

  use GenServer

  alias Phoenix.PubSub

  @topic "notifications_errors"

  alias FzHttpWeb.NotificationsLive

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def current, do: GenServer.call(__MODULE__, :current)
  def topic, do: @topic

  @impl GenServer
  def init(errors) do
    PubSub.subscribe(FzHttp.PubSub, topic())
    {:ok, errors}
  end

  @impl GenServer
  def handle_call(:current, _from, errors) do
    {:reply, errors, errors}
  end

  @impl GenServer
  def handle_info(%{error: message}, errors) do
    new_errors = errors ++ [message]

    PubSub.broadcast(
      FzHttp.PubSub,
      NotificationsLive.Index.errors_topic(),
      {:errors, new_errors}
    )

    {:noreply, new_errors}
  end
end
