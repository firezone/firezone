defmodule FzVpn.CLI.Live do
  @moduledoc """
  A low-level module that wraps common WireGuard CLI operations.
  Currently, these are very Linux-specific. In the future,
  this could be generalized to any *nix platform that supports a WireGuard
  client.

  See FzVpn.Server for higher-level functionality.
  """

  alias FzVpn.Config
  import FzCommon.CLI
  require Logger

  def setup do
    :ok = GenServer.call(:global.whereis_name(:fz_wall_server), :setup)
  end

  def teardown do
    :ok = GenServer.call(:global.whereis_name(:fz_wall_server), :teardown)
  end

  def remove_peer(public_key) do
    set("peer #{public_key} remove")
    Config.delete_psk(public_key)
  end

  def set(config_str) do
    # Empty config string results in invalid command
    if String.length(config_str) > 0 do
      exec!("#{wg()} set #{iface_name()} #{config_str}")
    end
  end

  def show_latest_handshakes do
    show("latest-handshakes")
  end

  def show_persistent_keepalive do
    show("persistent-keepalive")
  end

  def show_transfer do
    show("transfer")
  end

  defp show(subcommand) do
    exec!("#{wg()} show #{iface_name()} #{subcommand}")
  end

  defp iface_name do
    Application.get_env(:fz_vpn, :wireguard_interface_name, "wg-firezone")
  end

  defp wg do
    Application.fetch_env!(:fz_vpn, :wg_path)
  end
end
