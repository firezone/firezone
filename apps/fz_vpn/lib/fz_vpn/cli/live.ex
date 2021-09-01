defmodule FzVpn.CLI.Live do
  @moduledoc """
  A low-level module that wraps common WireGuard CLI operations.
  Currently, these are very Linux-specific. In the future,
  this could be generalized to any *nix platform that supports a WireGuard
  client.

  See FzVpn.Server for higher-level functionality.
  """

  # Outputs the privkey, then pubkey on the next line
  @genkey_cmd "wg genkey | tee >(wg pubkey)"
  @genpsk_cmd "wg genpsk"

  import FzCommon.CLI

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
    [privkey, pubkey] =
      exec!(@genkey_cmd)
      |> String.trim()
      |> String.split("\n")

    {privkey, pubkey}
  end

  def genpsk do
    exec!(@genpsk_cmd)
    |> String.trim()
  end

  def pubkey(privkey) when is_nil(privkey), do: nil

  def pubkey(privkey) when is_binary(privkey) do
    exec!("echo #{privkey} | wg pubkey")
    |> String.trim()
  end

  def set(config_str) do
    exec!("#{wg()} set #{iface_name()} #{config_str}")
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
