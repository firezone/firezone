defmodule FzHttp.EventsTest do
  @moduledoc """
  XXX: Use start_supervised! somehow here to allow async tests.
  """
  use FzHttp.DataCase, async: false

  alias FzHttp.{Devices, Events}

  # XXX: Not needed with start_supervised!
  setup do
    on_exit(fn ->
      :sys.replace_state(Events.vpn_pid(), fn _state -> %{} end)

      :sys.replace_state(Events.wall_pid(), fn _state ->
        {MapSet.new(), MapSet.new(), MapSet.new()}
      end)
    end)
  end

  describe "update_device/1" do
    setup [:create_device]

    test "adds device to peer config", %{device: device} do
      assert :ok == Events.update_device(device)

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key => %{
                 allowed_ips: "#{device.ipv4}/32,#{device.ipv6}/128",
                 preshared_key: nil
               }
             }
    end
  end

  describe "device_update/1 with rules" do
    setup [:create_rule_with_user_and_device]

    test "updates peer config", %{device: device, user: user, rule: rule} do
      assert :ok = Events.create_user(user)
      assert :ok = Events.update_device(device)
      assert :ok = Events.add_rule(rule)

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key => %{
                 allowed_ips: "#{device.ipv4}/32,#{device.ipv6}/128",
                 preshared_key: nil
               }
             }

      expected_state =
        {MapSet.new([user.id]),
         MapSet.new([%{ip: "10.3.2.2", ip6: "fd00::3:2:2", user_id: user.id}]),
         MapSet.new([%{action: :drop, destination: "10.20.30.0/24", user_id: user.id}])}

      assert ^expected_state = :sys.get_state(Events.wall_pid())
    end
  end

  describe "delete_device/1" do
    setup [:create_device]

    test "removes from peer config", %{device: device} do
      pubkey = device.public_key
      assert {:ok, ^pubkey} = Events.delete_device(device)

      assert :sys.get_state(Events.vpn_pid()) == %{}
    end
  end

  describe "Delete and add user/device/rule" do
    setup [:create_rule_with_user_and_device, :create_rules]

    test "add and remove user/device/rule", %{device: device, rule: rule, user: user} do
      assert :ok = Events.create_user(user)
      assert :ok = Events.add_rule(rule)
      assert :ok = Events.update_device(device)

      assert :sys.get_state(Events.wall_pid()) ==
               {MapSet.new([user.id]),
                MapSet.new([%{ip: "10.3.2.2", ip6: "fd00::3:2:2", user_id: user.id}]),
                MapSet.new([%{action: :drop, destination: "10.20.30.0/24", user_id: user.id}])}

      assert {:ok, _} = Events.delete_device(device)

      assert :sys.get_state(Events.vpn_pid()) == %{
               "4" => %{
                 allowed_ips: "10.3.2.4/32,fd00::3:2:4/128",
                 preshared_key: nil
               },
               "5" => %{
                 allowed_ips: "10.3.2.5/32,fd00::3:2:5/128",
                 preshared_key: nil
               },
               "6" => %{
                 allowed_ips: "10.3.2.6/32,fd00::3:2:6/128",
                 preshared_key: nil
               }
             }

      assert :sys.get_state(Events.wall_pid()) ==
               {MapSet.new([user.id]), MapSet.new(),
                MapSet.new([%{action: :drop, destination: "10.20.30.0/24", user_id: user.id}])}

      assert :ok = Events.delete_rule(rule)

      assert :sys.get_state(Events.wall_pid()) ==
               {MapSet.new([user.id]), MapSet.new(), MapSet.new()}

      assert :ok = Events.delete_user(user)

      assert :sys.get_state(Events.wall_pid()) == {MapSet.new(), MapSet.new(), MapSet.new()}
    end
  end

  describe "add_rule/1 and delete_rule/1" do
    setup [:create_rule]

    test "adds rule and deletes rule", %{rule: rule} do
      :ok = Events.add_rule(rule)

      assert :sys.get_state(Events.wall_pid()) ==
               {MapSet.new(), MapSet.new(),
                MapSet.new([%{destination: "10.10.10.0/24", user_id: nil, action: :drop}])}

      :ok = Events.delete_rule(rule)
      assert :sys.get_state(Events.wall_pid()) == {MapSet.new(), MapSet.new(), MapSet.new()}
    end
  end

  describe "add_rule/1 accept" do
    setup [:create_rule_accept]

    test "adds rule and deletes rule", %{rule: rule} do
      :ok = Events.add_rule(rule)

      assert :sys.get_state(Events.wall_pid()) ==
               {MapSet.new(), MapSet.new(),
                MapSet.new([%{destination: "10.10.10.0/24", user_id: nil, action: :accept}])}
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
              ip: FzHttp.Rules.decode(device.ipv4),
              ip6: FzHttp.Rules.decode(device.ipv6)
            }
          end)
        )

      expected_rules =
        MapSet.new(
          Enum.map(expected_rules, fn rule ->
            %{
              user_id: rule.user_id,
              destination: FzHttp.Rules.decode(rule.destination),
              action: rule.action
            }
          end)
        )

      assert {^expected_user_ids, ^expected_devices, ^expected_rules} =
               :sys.get_state(Events.wall_pid())
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
