defmodule FzVpn.StatsPushService do
  @moduledoc """
  Service to periodically push WireGuard statistics to fz_http.
  """
  use GenServer

  alias FzVpn.Interface
  alias FzVpn.Server

  # 60 seconds
  @interval 60_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, [])
  end

  @impl GenServer
  def init(state) do
    :timer.send_interval(@interval, :perform)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:perform, _state) do
    {:noreply, push_stats()}
  end

  def push_stats do
    GenServer.call(Server.http_pid(), {:update_device_stats, Interface.dump(Server.iface_name())})
  end
end
