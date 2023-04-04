defmodule Domain.Notifications do
  @moduledoc """
  Notification notifications for notifications live view.
  """
  use GenServer
  alias Phoenix.PubSub

  @topic "notifications_live"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @doc """
  Gets a list of current notifications.
  """
  def current, do: current(__MODULE__)
  def current(nil), do: current()
  def current(pid), do: GenServer.call(pid, :current)

  @doc """
  Add a notification.
  """
  def add(notification), do: add(__MODULE__, notification)
  def add(nil, notification), do: add(notification)
  def add(pid, notification), do: GenServer.call(pid, {:add, notification})

  @doc """
  Clear all notifications.
  """
  def clear_all, do: clear_all(__MODULE__)
  def clear_all(nil), do: clear_all()
  def clear_all(pid), do: GenServer.call(pid, :clear_all)

  @doc """
  Clear the given notification.
  """
  def clear(notification), do: clear(__MODULE__, notification)
  def clear(nil, notification), do: clear(notification)
  def clear(pid, notification), do: GenServer.call(pid, {:clear, notification})

  @doc """
  Clear a notification at the given index.
  """
  def clear_at(index), do: clear_at(__MODULE__, index)
  def clear_at(nil, index), do: clear_at(index)
  def clear_at(pid, index), do: GenServer.call(pid, {:clear_at, index})

  defp broadcast(notifications) do
    PubSub.broadcast(
      Domain.PubSub,
      @topic,
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
