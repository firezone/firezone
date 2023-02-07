defmodule FzHttp.EventsTest do
  @moduledoc """
  XXX: Use start_supervised! somehow here to allow async tests.
  """
  use FzHttp.DataCase, async: false

  alias FzHttp.{Devices, Events}

  @moduletag :acceptance

  # XXX: Not needed with start_supervised!
  setup do
    on_exit(fn ->
      :sys.replace_state(Events.vpn_pid(), fn _state -> %{} end)

      :sys.replace_state(Events.wall_pid(), fn _state ->
        %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
      end)
    end)
  end

  describe "add_device/1" do
    setup [:create_rule_with_user_and_device]

    test "adds device to wall and vpn state", %{device: device, user: user} do
      :ok = Events.add("devices", device)

      assert :sys.get_state(Events.wall_pid()) ==
               %{
                 users: MapSet.new(),
                 devices:
                   MapSet.new([%{ip: "#{device.ipv4}", ip6: "#{device.ipv6}", user_id: user.id}]),
                 rules: MapSet.new()
               }

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key => %{
                 allowed_ips: "#{device.ipv4}/32,#{device.ipv6}/128",
                 preshared_key: device.preshared_key
               }
             }
    end
  end

  describe "delete_device/1" do
    setup [:create_rule_with_user_and_device]

    test "removes device from vpn and wall state", %{device: device} do
      :ok = Events.add("devices", device)

      assert :ok = Events.delete("devices", device)

      assert :sys.get_state(Events.vpn_pid()) == %{}

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
    end
  end

  describe "create_user/1" do
    setup [:create_rule_with_user_and_device]

    test "Adds user to wall state", %{user: user} do
      :ok = Events.add("users", user)

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: MapSet.new([user.id]), devices: MapSet.new(), rules: MapSet.new()}
    end
  end

  describe "delete_user/1" do
    setup [:create_rule_with_user_and_device]

    test "removes user from wall state", %{user: user} do
      :ok = Events.add("users", user)
      :ok = Events.delete("users", user)

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
    end
  end

  describe "add_rule/1" do
    setup [:create_rule]

    test "adds rule to wall state", %{rule: rule} do
      :ok = Events.add("rules", rule)

      assert :sys.get_state(Events.wall_pid()) ==
               %{
                 users: MapSet.new(),
                 devices: MapSet.new(),
                 rules:
                   MapSet.new([
                     %{
                       destination: "10.10.10.0/24",
                       port_range: nil,
                       port_type: nil,
                       user_id: nil,
                       action: :drop
                     }
                   ])
               }
    end
  end

  describe "add_rule/1 accept" do
    setup [:create_rule_accept]

    test "adds rule to wall state", %{rule: rule} do
      :ok = Events.add("rules", rule)

      assert :sys.get_state(Events.wall_pid()) ==
               %{
                 users: MapSet.new(),
                 devices: MapSet.new(),
                 rules:
                   MapSet.new([
                     %{
                       destination: "10.10.10.0/24",
                       user_id: nil,
                       action: :accept,
                       port_type: nil,
                       port_range: nil
                     }
                   ])
               }
    end
  end

  describe "remove_rule/1" do
    setup [:create_rule]

    test "adds rule to wall state", %{rule: rule} do
      :ok = Events.add("rules", rule)
      :ok = Events.delete("rules", rule)

      assert :sys.get_state(Events.wall_pid()) == %{
               users: MapSet.new(),
               rules: MapSet.new(),
               devices: MapSet.new()
             }
    end
  end

  describe "set_config/0" do
    setup [:create_devices]

    test "sets config" do
      :ok = Events.set_config()

      assert :sys.get_state(Events.vpn_pid()) ==
               Map.new(Devices.to_peer_list(), fn peer ->
                 {peer.public_key, %{allowed_ips: peer.inet, preshared_key: peer.preshared_key}}
               end)
    end
  end

  describe "set_rules/0" do
    setup [:create_rules]

    test "sets rules", %{
      rules: expected_rules,
      users: expected_users,
      devices: expected_devices
    } do
      :ok = Events.set_rules()

      expected_user_ids = MapSet.new(Enum.map(expected_users, fn user -> user.id end))

      expected_devices =
        MapSet.new(
          Enum.map(expected_devices, fn device ->
            %{
              # XXX: Ideally we could hardcode the expected ips here as not to depend on the `decode` implementation
              # However, we can't know user_id in advance, perhaps we can test the user_id part and ip parts separately
              user_id: device.user_id,
              ip: FzHttp.Devices.decode(device.ipv4),
              ip6: FzHttp.Devices.decode(device.ipv6)
            }
          end)
        )

      expected_rules =
        MapSet.new(
          Enum.map(expected_rules, fn rule ->
            %{
              user_id: rule.user_id,
              destination: FzHttp.Devices.decode(rule.destination),
              action: rule.action,
              port_range: nil,
              port_type: nil
            }
          end)
        )

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: expected_user_ids, devices: expected_devices, rules: expected_rules}
    end
  end

  describe "vpn_pid/0" do
    test "uses the correct pid" do
      assert Events.vpn_pid() == :global.whereis_name(:fz_vpn_server)
    end
  end

  describe "wall_pid/0" do
    test "uses the correct pid" do
      assert Events.wall_pid() == :global.whereis_name(:fz_wall_server)
    end
  end
end
