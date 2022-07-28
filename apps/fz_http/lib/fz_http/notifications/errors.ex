defmodule FzHttp.Notifications.Errors do
  @moduledoc """
  Track error notification state for notifications live view.
  """

  use GenServer

  alias Phoenix.PubSub

  alias FzHttpWeb.NotificationsLive

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def current, do: GenServer.call(__MODULE__, :current)

  def add(error), do: GenServer.call(__MODULE__, {:add, error})

  def clear, do: GenServer.call(__MODULE__, :clear_all)

  def clear(message), do: GenServer.call(__MODULE__, {:clear, message})

  @impl GenServer
  def init(errors) do
    {:ok, errors}
  end

  @impl GenServer
  def handle_call(:current, _from, errors) do
    {:reply, errors, errors}
  end

  @impl GenServer
  def handle_call(:clear_all, _from, _errors) do
    {:reply, :ok, []}
  end

  @impl GenServer
  def handle_call({:clear, message}, _from, errors) do
    {:reply, :ok, Enum.reject(errors, &(&1 == message))}
  end

  @impl GenServer
  def handle_call({:add, %{error: message}}, _from, errors) do
    new_errors = [message | errors]

    PubSub.broadcast(
      FzHttp.PubSub,
      NotificationsLive.Index.errors_topic(),
      {:errors, new_errors}
    )

    {:reply, :ok, new_errors}
  end
end
