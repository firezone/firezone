defmodule FgHttpWeb.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FgHttp.{Devices, Rules, Rules.Rule}

  def create_device do
    GenServer.call(vpn_pid(), :create_device)
  end

  def delete_device(device_pubkey) do
    GenServer.call(vpn_pid(), {:delete_device, device_pubkey})
  end

  def add_rule(rule) do
    GenServer.call(wall_pid(), {:add_rule, Rule.iptables_spec(rule)})
  end

  def delete_rule(rule) do
    GenServer.call(wall_pid(), {:delete_rule, Rule.iptables_spec(rule)})
  end

  def set_config do
    GenServer.call(vpn_pid(), {:set_config, Devices.to_peer_list()})
  end

  def set_rules do
    GenServer.call(wall_pid(), {:set_rules, Rules.to_iptables()})
  end

  def vpn_pid do
    :global.whereis_name(:fg_vpn_server)
  end

  def wall_pid do
    :global.whereis_name(:fg_wall_server)
  end
end
