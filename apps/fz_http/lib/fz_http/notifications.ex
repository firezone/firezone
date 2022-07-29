defmodule FzHttp.Notifications do
  @moduledoc """
  Notification state for notifications live view.
  """
  use GenServer

  alias Phoenix.PubSub

  alias FzHttpWeb.NotificationsLive

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def current, do: GenServer.call(__MODULE__, :current)

  def add(notification), do: GenServer.call(__MODULE__, {:add, notification})

  def clear, do: GenServer.call(__MODULE__, :clear_all)

  def clear(notification), do: GenServer.call(__MODULE__, {:clear, notification})

  @impl GenServer
  def init(notifications) do
    {:ok, notifications}
  end

  @impl GenServer
  def handle_call(:current, _from, notifications) do
    {:reply, notifications, notifications}
  end

  @impl GenServer
  def handle_call(:clear_all, _from, _notifications) do
    {:reply, :ok, %{notifications: []}}
  end

  @impl GenServer
  def handle_call({:clear, notification}, _from, notifications) do
    {:reply, :ok, Enum.reject(notifications, &(&1 == notification))}
  end

  @impl GenServer
  def handle_call({:add, notification}, _from, notifications) do
    new_notifications = [notification | notifications]

    PubSub.broadcast(
      FzHttp.PubSub,
      NotificationsLive.Index.topic(),
      {:notifications, new_notifications}
    )

    {:reply, :ok, new_notifications}
  end
end
