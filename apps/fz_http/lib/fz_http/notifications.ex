defmodule FzHttp.Notifications do
  @moduledoc """
  Notification notifications for notifications live view.
  """
  use GenServer

  alias Phoenix.PubSub
  import FzHttpWeb.NotificationsLive.Index, only: [topic: 0]

  def start_link(opts \\ []) do
    if opts[:name] do
      GenServer.start_link(__MODULE__, [], name: opts[:name])
    else
      GenServer.start_link(__MODULE__, [])
    end
  end

  @doc """
  Gets a list of current notifications.
  """
  def current(pid \\ __MODULE__), do: GenServer.call(pid, :current)

  @doc """
  Add a notification.
  """
  def add(pid \\ __MODULE__, notification), do: GenServer.call(pid, {:add, notification})

  @doc """
  Clear all notifications.
  """
  def clear_all(pid \\ __MODULE__), do: GenServer.call(pid, :clear_all)

  @doc """
  Clear the given notification.
  """
  def clear(pid \\ __MODULE__, notification), do: GenServer.call(pid, {:clear, notification})

  @doc """
  Clear a notification at the given index.
  """
  def clear_at(pid \\ __MODULE__, index), do: GenServer.call(pid, {:clear_at, index})

  defp broadcast(notifications) do
    PubSub.broadcast(
      FzHttp.PubSub,
      topic(),
      {:notifications, notifications}
    )
  end

  @impl GenServer
  def init(notifications) do
    {:ok, notifications}
  end

  @impl GenServer
  def handle_call(:current, _from, notifications) do
    {:reply, notifications, notifications}
  end

  @impl GenServer
  def handle_call({:add, notification}, _from, notifications) do
    new_notifications = [notification | notifications]
    broadcast(new_notifications)

    {:reply, :ok, new_notifications}
  end

  @impl GenServer
  def handle_call(:clear_all, _from, _notifications) do
    broadcast([])

    {:reply, :ok, []}
  end

  @impl GenServer
  def handle_call({:clear, notification}, _from, notifications) do
    new_notifications = Enum.reject(notifications, &(&1 == notification))
    broadcast(new_notifications)

    {:reply, :ok, new_notifications}
  end

  @impl GenServer
  def handle_call({:clear_at, index}, _from, notifications) do
    {_, new_notifications} = List.pop_at(notifications, index)
    broadcast(new_notifications)

    {:reply, :ok, new_notifications}
  end
end
