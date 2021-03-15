defmodule FgVpn.Config do
  @moduledoc """
  Functions for managing the WireGuard configuration.
  """

  @default_interface_ip "172.16.59.1"

  import FgVpn.CLI

  defstruct interface_ip: @default_interface_ip,
            listen_port: 51_820,
            peers: MapSet.new([])

  def render(config) do
    "private-key #{private_key()} listen-port #{config.listen_port} " <>
      Enum.join(
        for peer <- config.peers do
          "peer #{peer.public_key} allowed-ips #{peer.allowed_ips} preshared-key #{
            peer.preshared_key
          }"
        end,
        " "
      )
  end

  def private_key do
    Application.get_env(:fg_vpn, :private_key)
  end

  def public_key do
    cli().pubkey(private_key())
  end
end
