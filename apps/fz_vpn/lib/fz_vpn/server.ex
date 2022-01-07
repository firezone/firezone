defmodule FzVpn.Server do
  @moduledoc """
  Functions for reading / writing the WireGuard config

  Startup:
  Set empty config

  Received events:
  - start: set config and apply it
  - new_peer: gen peer pubkey, return it, but don't apply config
  - commit_peer: commit pending peer to config
  - remove_peer: remove peer

  Config is a data structure that looks like this:

  %{
    pubkey1 => {device1_ipv4, device1_ipv6},
    pubkey2 => {device2_ipv4, device2_ipv6},
    ...
  }
  """

  alias FzVpn.Config
  use GenServer
  import FzVpn.CLI
  require Logger

  @process_opts Application.compile_env(:fz_vpn, :server_process_opts, [])
  @init_timeout 1_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, @process_opts)
  end

  @impl GenServer
  def init(_config) do
    cli().setup()
    {:ok, peers} = GenServer.call(http_pid(), :load_peers, @init_timeout)
    config = peers_to_config(peers)
    apply_config_diff(config)
  end

  @impl GenServer
  def handle_call(:create_device, _from, config) do
    server_pubkey = Application.get_env(:fz_vpn, :wireguard_public_key)
    {privkey, pubkey} = cli().genkey()
    {:reply, {:ok, privkey, pubkey, server_pubkey}, config}
  end

  @impl GenServer
  def handle_call({:delete_device, pubkey}, _from, config) do
    cli().delete_peer(pubkey)
    new_config = Map.delete(config, pubkey)
    {:reply, {:ok, pubkey}, new_config}
  end

  @impl GenServer
  def handle_call({:set_config, peers}, _from, config) do
    new_config = peers_to_config(peers)
    apply_config_diff(config, new_config)
    {:reply, :ok, new_config}
  end

  @impl GenServer
  def handle_call({:update_device, pubkey, inet}, _from, config) do
    cli().set_peer(pubkey, inet)
    {:reply, :ok, Map.put(config, pubkey, inet)}
  end

  @doc """
  Determines which peers to remove, add, and change and sets them on the WireGuard interface.
  """
  def apply_config_diff(old_config \\ %{}, new_config) do
    delete_old_peers(old_config, new_config)
    update_changed_peers(old_config, new_config)
    {:ok, new_config}
  end

  defp delete_old_peers(old_config, new_config) do
    for pubkey <- Map.keys(old_config) -- Map.keys(new_config) do
      cli().delete_peer(pubkey)
    end
  end

  defp update_changed_peers(old_config, new_config) do
    new_config
    |> Enum.filter(fn {pubkey, inet} -> Map.get(old_config, pubkey) != inet end)
    |> Config.render()
    |> cli().set()
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end

  defp peers_to_config(peers) do
    Map.new(peers, fn peer -> {peer.public_key, peer.inet} end)
  end
end
