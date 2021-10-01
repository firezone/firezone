defmodule FzVpn.CLI.Live do
  @moduledoc """
  A low-level module that wraps common WireGuard CLI operations.
  Currently, these are very Linux-specific. In the future,
  this could be generalized to any *nix platform that supports a WireGuard
  client.

  See FzVpn.Server for higher-level functionality.
  """

  # Outputs the privkey
  @genkey_cmd "wg genkey"

  import FzCommon.CLI
  require Logger

  def setup do
    :ok = GenServer.call(:global.whereis_name(:fz_wall_server), :setup)
  end

  def teardown do
    :ok = GenServer.call(:global.whereis_name(:fz_wall_server), :teardown)
  end

  @doc """
  Calls wg genkey
  """
  def genkey do
    privkey =
      exec!(@genkey_cmd)
      |> String.trim()

    {privkey, pubkey(privkey)}
  end

  def set_peer(pubkey, {ipv4, ipv6}) do
    set("peer #{pubkey} allowed-ips #{ipv4}/32,#{ipv6}/128")
  end

  def delete_peer(pubkey) do
    set("peer #{pubkey} remove")
  end

  def pubkey(privkey) when is_nil(privkey), do: nil

  def pubkey(privkey) when is_binary(privkey) do
    exec!("echo #{privkey} | wg pubkey")
    |> String.trim()
  end

  def set(config_str) do
    # Empty config string results in invalid command
    if String.length(config_str) > 0 do
      exec!("#{wg()} set #{iface_name()} #{config_str}")
    else
      Logger.warn("""
      Attempted to set empty WireGuard config string. Most of the time this can be safely ignored.
      """)
    end
  end

  def show_latest_handshakes do
    show("latest-handshakes")
  end

  def show_persistent_keepalives do
    show("persistent-keepalives")
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
