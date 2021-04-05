defmodule FgVpn.Server do
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

  alias FgVpn.{Config, Peer}
  use GenServer
  import FgVpn.CLI
  require Logger

  @process_opts Application.compile_env(:fg_vpn, :server_process_opts)

  def start_link(_) do
    cli().setup()
    GenServer.start_link(__MODULE__, %Config{}, @process_opts)
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

  @doc """
  Apply configuration to interface.
  """
  def apply(config) do
    cli().set(Config.render(config))
  end
end
