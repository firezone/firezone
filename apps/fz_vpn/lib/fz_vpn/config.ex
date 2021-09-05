defmodule FzVpn.Config do
  @moduledoc """
  Functions for managing the WireGuard configuration.
  """

  import FzVpn.CLI

  defstruct peers: MapSet.new([])

  def render(config) do
    "private-key #{private_key()} listen-port #{listen_port()} " <>
      Enum.join(
        for peer <- config.peers do
          "peer #{peer.public_key} allowed-ips #{peer.allowed_ips} preshared-key #{peer.preshared_key}"
        end,
        " "
      )
  end

  def private_key do
    Application.get_env(:fz_vpn, :wireguard_private_key)
  end

  def public_key do
    cli().pubkey(private_key())
  end

  def listen_port do
    Application.get_env(:fz_vpn, :wireguard_port)
  end
end
