defmodule FzVpn.StatsPushService do
  @moduledoc """
  Service to periodically push WireGuard statistics to fz_http.
  """
  use GenServer
  import FzVpn.CLI
  alias FzVpn.Server

  # 1 minute
  @interval 3_600
  @dump_fields [
    :preshared_key,
    :endpoint,
    :allowed_ips,
    :latest_handshake,
    :rx_bytes,
    :tx_bytes,
    :persistent_keepalive
  ]

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
    GenServer.call(Server.http_pid(), {:update_device_stats, dump()})
  end

  # XXX: Consider using MapSet for this instead of List
  def dump do
    cli().show_dump()
    |> String.split("\n")
    # first line is interface info
    |> Enum.drop(1)
    # chomp empty last item
    |> Enum.drop(-1)
    |> Enum.map(&String.split(&1, "\t"))
    |> Enum.map(fn fields ->
      [public_key | remaining_fields] = fields

      {
        public_key,
        @dump_fields
        |> Enum.zip(remaining_fields)
        |> Map.new()
      }
    end)
    |> Map.new()
  end
end
