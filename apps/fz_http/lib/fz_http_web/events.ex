defmodule FzHttpWeb.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{Devices, Rules, Settings, Users}

  def create_device do
    GenServer.call(vpn_pid(), :create_device)
  end

  def device_created(device) do
    user = Users.get_user!(device.user_id)

    unless Users.vpn_session_expired?(user, Settings.vpn_duration()) do
      GenServer.cast(vpn_pid(), {
        :device_created,
        device.public_key,
        "#{Devices.ipv4_address(device)},#{Devices.ipv6_address(device)}"
      })
    end
  end

  def device_updated(device) do
    GenServer.cast(vpn_pid(), {
      :device_updated,
      device.public_key,
      "#{Devices.ipv4_address(device)},#{Devices.ipv6_address(device)}"
    })
  end

  def delete_device(device_pubkey) when is_binary(device_pubkey) do
    GenServer.call(vpn_pid(), {:delete_device, device_pubkey})
  end

  def delete_device(device) when is_struct(device) do
    delete_device(device.public_key)
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
