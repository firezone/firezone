defmodule FzHttp.TelemetryPingService do
  @moduledoc """
  Periodic service for sending `ping` telemetry
  events.
  """
  use GenServer
  alias FzHttp.Telemetry

  @interval 3_600

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl GenServer
  def init(state) do
    # Send ping every hour
    :timer.send_interval(@interval * 1000, :perform)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:perform, state) do
    Telemetry.ping()
    {:noreply, state}
  end
end
