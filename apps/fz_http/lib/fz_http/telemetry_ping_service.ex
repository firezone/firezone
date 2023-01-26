defmodule FzHttp.TelemetryPingService do
  @moduledoc """
  Periodic service for sending `ping` telemetry
  events.
  """
  use GenServer
  alias FzHttp.Telemetry

  @initial_delay 60 * 1_000
  @interval 43_200

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl GenServer
  def init(state) do
    # Send ping after 1 minute
    :timer.send_after(@initial_delay, :perform)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:perform, state) do
    Telemetry.ping()
    # Continue pinging twice a day
    :timer.send_interval(@interval * 1_000, :perform)
    {:noreply, state}
  end
end
