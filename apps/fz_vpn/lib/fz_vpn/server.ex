defmodule FzVpn.Server do
  @moduledoc """
  Functions for reading / writing the WireGuard config.
  """

  use GenServer
  require Logger

  alias FzVpn.Interface
  alias FzVpn.Keypair

  @init_timeout 10_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: {:global, :fz_vpn_server})
  end

  @impl GenServer
  def init(_config) do
    setup_interface()
    {:ok, peers} = GenServer.call(http_pid(), :load_peers, @init_timeout)
    config = peers_to_config(peers)
    apply_config_diff(config)
  end

  @impl GenServer
  def handle_call({:remove_peer, public_key}, _from, config) do
    case Interface.remove_peer(iface_name(), public_key) do
      :ok ->
        {:reply, :ok, Map.delete(config, public_key)}

      err ->
        {:reply, err, config}
    end
  end

  @impl GenServer
  def handle_call({:set_config, peers}, _from, config) do
    new_config = peers_to_config(peers)
    {res, resp} = apply_config_diff(config, new_config)
    {:reply, res, resp}
  end

  @doc """
  Determines which peers to remove, add, and change and sets them on the WireGuard interface.
  """
  def apply_config_diff(old_config \\ %{}, new_config) do
    delete_old_peers(old_config, new_config)
    update_changed_peers(old_config, new_config)
  end

  def iface_name do
    Application.get_env(:fz_vpn, :wireguard_interface_name, "wg-firezone")
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end

  defp setup_interface do
    private_key = Keypair.load_or_generate_private_key()
    listen_port = Application.fetch_env!(:fz_vpn, :wireguard_port)
    Interface.set(iface_name(), %{}, private_key: private_key, listen_port: listen_port)
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
    |> case do
      :ok -> {:ok, new_config}
      {:error, _error_info} -> {:error, old_config}
    end
  end

  defp set_peers(peers) do
    Interface.set(iface_name(), peers)
  end

  defp peers_to_config(peers) do
    Map.new(peers, fn peer ->
      {peer.public_key, %{allowed_ips: peer.inet, preshared_key: peer.preshared_key}}
    end)
  end
end
