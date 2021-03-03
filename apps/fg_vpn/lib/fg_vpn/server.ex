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
  def handle_info({:create_device, sender}, config) do
    server_pubkey = Config.public_key()
    {privkey, pubkey} = cli().genkey()
    psk = cli().genpsk()
    uncommitted_peers = MapSet.put(config.uncommitted_peers, pubkey)
    new_config = Map.put(config, :uncommitted_peers, uncommitted_peers)

    send(sender, {:device_created, privkey, pubkey, server_pubkey, psk})
    {:noreply, new_config}
  end

  @impl true
  def handle_info({:commit_peer, %{} = attrs}, config) do
    new_config =
      if MapSet.member?(config.uncommitted_peers, attrs[:public_key]) do
        new_peer = Map.merge(%Peer{}, attrs)
        new_peers = MapSet.put(config.peers, new_peer)
        new_uncommitted_peers = MapSet.delete(config.uncommitted_peers, attrs[:public_key])

        config
        |> Map.put(:uncommitted_peers, new_uncommitted_peers)
        |> Map.put(:peers, new_peers)
      else
        config
      end

    apply(new_config)

    {:noreply, new_config}
  end

  @impl true
  def handle_info({:remove_peer, pubkey}, config) do
    new_peers = MapSet.delete(config.peers, %Peer{public_key: pubkey})
    new_config = %{config | peers: new_peers}
    apply(new_config)
    {:noreply, new_config}
  end

  @impl true
  def handle_cast({:set_config, new_config}, _config) do
    {:noreply, new_config}
  end

  @doc """
  Apply configuration to interface.
  """
  def apply(config) do
    cli().set(Config.render(config))
  end
end
