defmodule FzHttp.VpnSessionScheduler do
  @moduledoc """
  Checks for VPN sessions to expire.
  """
  use GenServer

  alias FzHttp.Events

  # 1 minute
  @interval 60 * 1_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl GenServer
  def init(state) do
    :timer.send_interval(@interval, :perform)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:perform, state) do
    {:noreply, state}
  end
end
