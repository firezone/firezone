defmodule FzHttp.Telemetry.Timer do
  use GenServer
  alias FzHttp.Telemetry

  @initial_delay 60 * 1_000
  @interval 43_200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Send ping after 1 minute
    :timer.send_after(@initial_delay, :start_interval)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:start_interval, state) do
    # Continue pinging twice a day
    :timer.send_interval(@interval * 1_000, :tick)

    :ok = Telemetry.ping()

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    :ok = Telemetry.ping()

    {:noreply, state}
  end
end
