defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{Devices, Rules}

  # set_config is used because devices need to be re-evaluated in case a
  # device is added to a User that's not active.
  def update_device(_device) do
    GenServer.call(vpn_pid(), {:set_config, Devices.to_peer_list()})
  end

  def delete_device(public_key) when is_binary(public_key) do
    GenServer.call(vpn_pid(), {:remove_peer, public_key})
  end

  def delete_device(device) when is_struct(device) do
    GenServer.call(vpn_pid(), {:remove_peer, device.public_key})
    GenServer.call(wall_pid(), {:delete_device_rules, {device.ipv4, device.ipv6}})
  end

  def add_rule(rule) do
    GenServer.call(wall_pid(), {:add_rule, Rules.nftables_spec(rule)})
  end

  def delete_rule(rule) do
    GenServer.call(wall_pid(), {:delete_rule, Rules.nftables_spec(rule)})
  end

  def set_config do
    GenServer.call(vpn_pid(), {:set_config, Devices.to_peer_list()})
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
