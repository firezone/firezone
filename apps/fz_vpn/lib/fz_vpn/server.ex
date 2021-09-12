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
    pubkey1 => device1_ip,
    pubkey2 => device2_ip,
  }
  """

  alias FzVpn.Config
  use GenServer
  import FzVpn.CLI
  require Logger

  @process_opts Application.compile_env(:fz_vpn, :server_process_opts)
  @init_timeout 1_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, @process_opts)
  end

  @impl GenServer
  def init(_config) do
    cli().setup()
    {:ok, peers} = GenServer.call(http_pid(), :load_peers, @init_timeout)
    config = Map.new(peers, fn peer -> {peer.public_key, peer.allowed_ips} end)
    apply_config(config)
  end

  @impl GenServer
  def handle_call(:create_device, _from, config) do
    server_pubkey = Application.get_env(:fz_vpn, :wireguard_public_key)
    {privkey, pubkey} = cli().genkey()
    {:reply, {:ok, privkey, pubkey, server_pubkey}, config}
  end

  @impl GenServer
  def handle_call({:delete_device, pubkey}, _from, config) do
    new_config = Map.delete(config, pubkey)
    cli().delete_peer(pubkey)
    apply_config(new_config)

    {:reply, {:ok, pubkey}, new_config}
  end

  @impl GenServer
  def handle_call({:set_config, new_config}, _from, _config) do
    apply_config(new_config)
    {:reply, :ok, new_config}
  end

  @impl GenServer
  def handle_cast({:device_created, pubkey, ip}, config) do
    cli().add_peer(pubkey, ip)
    {:noreply, Map.put(config, pubkey, ip)}
  end

  @doc """
  Apply configuration to interface.
  """
  def apply_config(config) do
    cli().set(Config.render(config))
    {:ok, config}
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end
end
