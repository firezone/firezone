defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{Devices, Rules, Users}

  # set_config is used because devices need to be re-evaluated in case a
  # device is added to a User that's not active.
  def update_device(device) do
    GenServer.call(wall_pid(), {:add_device, Devices.setting_projection(device)})
    GenServer.call(vpn_pid(), {:set_config, Devices.to_peer_list()})
  end

  def delete_device(device) do
    GenServer.call(wall_pid(), {:delete_device, Devices.setting_projection(device)})
    GenServer.call(vpn_pid(), {:remove_peer, device.public_key})
  end

  def delete_user(user) do
    GenServer.call(wall_pid(), {:delete_user, Users.setting_projection(user)})
  end

  def create_user(user) do
    # Security note: It's important to let an exception here crash this service
    # otherwise, nft could have succeeded in adding the user's set but not the rules
    # this means that in `update_device` add_device can succeed adding the device to the user's set
    # but any rule for the user won't take effect since the user rule doesn't exists.
    GenServer.call(wall_pid(), {:add_user, Users.setting_projection(user)})
  end

  def add_rule(rule) do
    GenServer.call(wall_pid(), {:add_rule, Rules.setting_projection(rule)})
  end

  def delete_rule(rule) do
    GenServer.call(wall_pid(), {:delete_rule, Rules.setting_projection(rule)})
  end

  def set_config do
    GenServer.call(vpn_pid(), {:set_config, Devices.to_peer_list()})
  end

  def set_rules do
    GenServer.call(
      wall_pid(),
      {:set_rules,
       %{
         users: Users.as_settings(),
         devices: Devices.as_settings(),
         rules: Rules.as_settings()
       }}
    )
  end

  def vpn_pid do
    :global.whereis_name(:fz_vpn_server)
  end

  def wall_pid do
    :global.whereis_name(:fz_wall_server)
  end
end
