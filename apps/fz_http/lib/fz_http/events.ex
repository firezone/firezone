defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{Devices, Rules, Users}
  alias FzHttpWeb.NotificationChannel

  # set_config is used because devices need to be re-evaluated in case a
  # device is added to a User that's not active.
  def add(subject, device) when subject == "devices" do
    with :ok <- GenServer.call(wall_pid(), {:add_device, Devices.setting_projection(device)}),
         :ok <- GenServer.call(vpn_pid(), {:set_config, Devices.to_peer_list()}) do
      :ok
    else
      _err ->
        NotificationChannel.send_to_channel(
          "error",
          %{
            error: %{
              user: Users.get_user!(device.user_id).email,
              message: """
              #{device.name} was created successfully but an error occured applying its
              configuration to the WireGuard interface. Check the logs for more
              information.
              """
            }
          }
        )
    end
  end

  def add(subject, rule) when subject == "rules" do
    GenServer.call(wall_pid(), {:add_rule, Rules.setting_projection(rule)})
  end

  def add(subject, user) when subject == "users" do
    # Security note: It's important to let an exception here crash this service
    # otherwise, nft could have succeeded in adding the user's set but not the rules
    # this means that in `update_device` add_device can succeed adding the device to the user's set
    # but any rule for the user won't take effect since the user rule doesn't exists.
    GenServer.call(wall_pid(), {:add_user, Users.setting_projection(user)})
  end

  def delete(subject, device) when subject == "devices" do
    with :ok <- GenServer.call(wall_pid(), {:delete_device, Devices.setting_projection(device)}),
         :ok <- GenServer.call(vpn_pid(), {:remove_peer, device.public_key}) do
      :ok
    else
      _err ->
        NotificationChannel.send_to_channel(
          "error",
          %{
            error: %{
              user: Users.get_user!(device.user_id).email,
              message: """
              #{device.name} was deleted successfully but an error occured applying its
              configuration to the WireGuard interface. Check the logs for more
              information.
              """
            }
          }
        )
    end
  end

  def delete(subject, rule) when subject == "rules" do
    GenServer.call(wall_pid(), {:delete_rule, Rules.setting_projection(rule)})
  end

  def delete(subject, user) when subject == "users" do
    GenServer.call(wall_pid(), {:delete_user, Users.setting_projection(user)})
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
