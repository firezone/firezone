defmodule FzVpn.Server do
  @moduledoc """
  Functions for reading / writing the WireGuard config.
  """

  use GenServer
  require Logger

  alias FzVpn.Interface

  @process_opts Application.compile_env(:fz_vpn, :server_process_opts, [])
  @init_timeout 1_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, @process_opts)
  end

  @impl GenServer
  def init(_config) do
    {:ok, peers} = GenServer.call(http_pid(), :load_peers, @init_timeout)
    config = peers_to_config(peers)
    apply_config_diff(config)
  end

  @impl GenServer
  def handle_call({:remove_peer, public_key}, _from, config) do
    Interface.remove_peer(iface_name(), public_key)
    new_config = Map.delete(config, public_key)
    {:reply, {:ok, public_key}, new_config}
  end

  @impl GenServer
  def handle_call({:set_config, peers}, _from, config) do
    new_config = peers_to_config(peers)
    apply_config_diff(config, new_config)
    {:reply, :ok, new_config}
  end

  @doc """
  Determines which peers to remove, add, and change and sets them on the WireGuard interface.
  """
  def apply_config_diff(old_config \\ %{}, new_config) do
    delete_old_peers(old_config, new_config)
    update_changed_peers(old_config, new_config)
    {:ok, new_config}
  end

  def iface_name do
    Application.get_env(:fz_vpn, :wireguard_interface_name, "wg-firezone")
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end

  defp delete_old_peers(old_config, new_config) do
    for public_key <- Map.keys(old_config) -- Map.keys(new_config) do
      Interface.remove_peer(iface_name(), public_key)
    end
  end

  defp update_changed_peers(old_config, new_config) do
    new_config
    |> Map.filter(fn {public_key, settings} -> Map.get(old_config, public_key) != settings end)
    |> set_peers()
  end

  defp set_peers(config) do
    Interface.set(iface_name(), nil, config)
  end

  defp peers_to_config(peers) do
    Map.new(peers, fn peer ->
      {peer.public_key, %{allowed_ips: peer.inet, preshared_key: peer.preshared_key}}
    end)
  end
end
