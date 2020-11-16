defmodule FgVpn.Config do
  @moduledoc """
  Maintains our own representation of the WireGuard config
  """
  use Agent

  @doc """
  Receive a list of devices and start maintaining config.
  """
  def start_link(pubkeys) do
    Agent.start_link(fn -> pubkeys end, name: __MODULE__)
  end

  def add_peer(pubkey) do
    Agent.update(__MODULE__, fn pubkeys -> [pubkey | pubkeys] end)
  end

  def remove_peer(pubkey) do
    Agent.update(__MODULE__, fn pubkeys -> List.delete(pubkeys, pubkey) end)
  end

  def list_peers do
    Agent.get(__MODULE__, fn pubkeys -> pubkeys end)
  end

  def write! do
    File.write!(Application.get_env(:fg_vpn, :wireguard_conf_path), render())
  end

  @doc """
  Renders WireGuard config in a deterministic way.
  """
  def render do
    "# BEGIN FIREGUARD-MANAGED PEER LIST\n" <>
      peers_to_config(list_peers()) <>
      "# END FIREGUARD-MANAGED PEER LIST"
  end

  defp peers_to_config(peers) do
    Enum.map_join(peers, fn pubkey ->
      ~s"""
      # BEGIN PEER #{pubkey}
      [Peer]
      PublicKey = #{pubkey}
      AllowedIPs = 0.0.0.0/0, ::/0
      # END PEER #{pubkey}
      """
    end)
  end
end
