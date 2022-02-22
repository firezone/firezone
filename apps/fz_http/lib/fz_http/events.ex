defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{Rules, Tunnels}

  # set_config is used because tunnels need to be re-evaluated in case a
  # tunnel is added to a User that's not active.
  def update_tunnel(_tunnel) do
    GenServer.call(vpn_pid(), {:set_config, Tunnels.to_peer_list()})
  end

  def delete_tunnel(tunnel_pubkey) when is_binary(tunnel_pubkey) do
    GenServer.call(vpn_pid(), {:remove_peer, tunnel_pubkey})
  end

  def delete_tunnel(tunnel) when is_struct(tunnel) do
    GenServer.call(vpn_pid(), {:remove_peer, tunnel.public_key})
  end

  def add_rule(rule) do
    GenServer.call(wall_pid(), {:add_rule, Rules.nftables_spec(rule)})
  end

  def delete_rule(rule) do
    GenServer.call(wall_pid(), {:delete_rule, Rules.nftables_spec(rule)})
  end

  def set_config do
    GenServer.call(vpn_pid(), {:set_config, Tunnels.to_peer_list()})
  end

  def set_rules do
    GenServer.call(wall_pid(), {:set_rules, Rules.to_nftables()})
  end

  def vpn_pid do
    :global.whereis_name(:fz_vpn_server)
  end

  def wall_pid do
    :global.whereis_name(:fz_wall_server)
  end
end
