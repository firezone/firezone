defmodule CfVpn.CLI.Live do
  @moduledoc """
  A low-level module that wraps common WireGuard CLI operations.
  Currently, these are very Linux-specific. In the future,
  this could be generalized to any *nix platform that supports a WireGuard
  client.

  See CfVpn.Server for higher-level functionality.
  """

  @egress_interface_cmd "route | grep '^default' | grep -o '[^ ]*$'"

  # Outputs the privkey, then pubkey on the next line
  @genkey_cmd "wg genkey | tee >(wg pubkey)"
  @genpsk_cmd "wg genpsk"
  @iface_name "wg-cloudfire"

  import CfCommon.CLI

  def setup do
    # create_interface()
    setup_iptables()
    up_interface()
  end

  def teardown do
    down_interface()
    teardown_iptables()
    # delete_interface()
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
    exec!("wg set #{@iface_name} #{config_str}")
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
    exec!("wg show #{@iface_name} #{subcommand}")
  end

  defp interface_exists do
    case bash("ifconfig -a | grep #{@iface_name}") do
      {_result, 0} -> true
      {_error, 1} -> false
    end
  end

  defp create_interface do
    unless interface_exists() do
      exec!("ip link add dev #{@iface_name} type wireguard")
    end
  end

  defp delete_interface do
    if interface_exists() do
      exec!("ip link dev delete #{@iface_name}")
    end
  end

  # XXX: Move to CfWall and call via PID?
  defp setup_iptables do
    exec!("\
      iptables -A FORWARD -i %i -j ACCEPT;\
      iptables -A FORWARD -o %i -j ACCEPT; \
      iptables -t nat -A POSTROUTING -o #{egress_interface()} -j MASQUERADE\
    ")
  end

  # XXX: Move to CfWall and call via PID?
  defp teardown_iptables do
    exec!("\
      iptables -D FORWARD -i %i -j ACCEPT;\
      iptables -D FORWARD -o %i -j ACCEPT;\
      iptables -t nat -D POSTROUTING -o #{egress_interface()} -j MASQUERADE\
    ")
  end

  defp up_interface do
    exec!("ifconfig #{@iface_name} up")
  end

  defp down_interface do
    exec!("ifconfig #{@iface_name} down")
  end
end
