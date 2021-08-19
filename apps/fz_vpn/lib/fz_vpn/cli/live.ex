defmodule FzVpn.CLI.Live do
  @moduledoc """
  A low-level module that wraps common WireGuard CLI operations.
  Currently, these are very Linux-specific. In the future,
  this could be generalized to any *nix platform that supports a WireGuard
  client.

  See FzVpn.Server for higher-level functionality.
  """

  @egress_interface_cmd "route | grep '^default' | grep -o '[^ ]*$'"

  # Outputs the privkey, then pubkey on the next line
  @genkey_cmd "wg genkey | tee >(wg pubkey)"
  @genpsk_cmd "wg genpsk"

  import FzCommon.CLI

  def setup do
    setup_iptables()
  end

  def teardown do
    teardown_iptables()
  end

  def interface_address do
    case :os.type() do
      {:unix, :linux} ->
        cmd = "ip address show dev #{iface_name()} | grep 'inet ' | awk '{print $2}'"

        exec!(cmd)
        |> String.trim()
        # Remove CIDR
        |> String.split("/")
        |> List.first()

      {:unix, :darwin} ->
        cmd = "ipconfig getifaddr #{iface_name()}"

        exec!(cmd)
        |> String.trim()

      _ ->
        raise "OS not supported (yet)"
    end
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
    exec!("wg set #{iface_name()} #{config_str}")
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

  defp egress_interface do
    case :os.type() do
      {:unix, :linux} ->
        exec!(@egress_interface_cmd)
        |> String.split()
        |> List.first()

      {:unix, :darwin} ->
        # XXX: Figure out what it means to have macOS as a host?
        "en0"
    end
  end

  defp show(subcommand) do
    exec!("wg show #{iface_name()} #{subcommand}")
  end

  # XXX: Move to FzWall and call via PID?
  defp setup_iptables do
    exec!("\
      iptables -A FORWARD -i %i -j ACCEPT;\
      iptables -A FORWARD -o %i -j ACCEPT;\
      iptables -t nat -A POSTROUTING -o #{egress_interface()} -j MASQUERADE\
    ")
  end

  # XXX: Move to FzWall and call via PID?
  defp teardown_iptables do
    exec!("\
      iptables -D FORWARD -i %i -j ACCEPT;\
      iptables -D FORWARD -o %i -j ACCEPT;\
      iptables -t nat -D POSTROUTING -o #{egress_interface()} -j MASQUERADE\
    ")
  end

  defp iface_name do
    Application.get_env(:fz_vpn, :wireguard_interface_name, "wg-firezone")
  end
end
