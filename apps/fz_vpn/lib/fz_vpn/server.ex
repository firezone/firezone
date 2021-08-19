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
  """

  alias FzVpn.{Config, Peer}
  use GenServer
  import FzVpn.CLI
  require Logger

  @process_opts Application.compile_env(:fz_vpn, :server_process_opts)

  def start_link(_) do
    cli().setup()

    case GenServer.start_link(__MODULE__, %Config{}, @process_opts) do
      {:ok, pid} ->
        :global.register_name(:fz_vpn_server, pid)
        {:ok, pid}

      res ->
        res
    end
  end

  @impl true
  def init(config) do
    {:ok, config}
  end

  @impl true
  def handle_call(:create_device, _from, config) do
    server_pubkey = Config.public_key()
    {privkey, pubkey} = cli().genkey()
    psk = cli().genpsk()

    new_config =
      Map.put(
        config,
        :peers,
        MapSet.put(config.peers, pubkey)
      )

    {:reply, {:ok, privkey, pubkey, server_pubkey, psk}, new_config}
  end

  @impl true
  def handle_call({:delete_device, pubkey}, _from, config) do
    new_peers = MapSet.delete(config.peers, %Peer{public_key: pubkey})
    new_config = %{config | peers: new_peers}
    apply(new_config)

    {:reply, {:ok, pubkey}, new_config}
  end

  @impl true
  def handle_call({:set_config, new_config}, _from, _config) do
    apply(new_config)
    {:reply, :ok, new_config}
  end

  @impl true
  def handle_call({:vpn_endpoint}, _from, _config) do
    interface_address = cli().interface_address()
    listen_port = Application.fetch_env!(:fz_vpn, :wireguard_listen_port)
    {:reply, :ok, "#{interface_address}:#{listen_port}"}
  end

  @doc """
  Apply configuration to interface.
  """
  def apply(config) do
    cli().set(Config.render(config))
  end
end
