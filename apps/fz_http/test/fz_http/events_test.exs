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
      :sys.replace_state(Events.wall_pid(), fn _state -> [] end)
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
    setup [:create_device_with_rules]

    test "updates peer config", %{device: device} do
      assert :ok = Events.update_device(device)

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key => %{
                 allowed_ips: "#{device.ipv4}/32,#{device.ipv6}/128",
                 preshared_key: nil
               }
             }

      assert :sys.get_state(Events.wall_pid()) == [
               {"10.3.2.2", "1.1.1.0/24", :drop},
               {"10.3.2.2", "2.2.2.0/24", :drop},
               {"10.3.2.2", "3.3.3.0/24", :drop},
               {"10.3.2.2", "4.4.4.0/24", :drop},
               {"fd00::3:2:2", "1::/112", :drop},
               {"fd00::3:2:2", "2::/112", :drop},
               {"fd00::3:2:2", "3::/112", :drop},
               {"fd00::3:2:2", "4::/112", :drop}
             ]
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

  describe "delete_device/1 with rules" do
    setup [:create_device_with_rules, :create_rules]

    test "removes from peer config", %{device: device, rules: rules} do
      assert :ok = Events.update_device(device)
      Enum.each(rules, fn rule -> assert :ok = Events.add_rule(rule) end)

      assert MapSet.equal?(
               MapSet.new(:sys.get_state(Events.wall_pid())),
               MapSet.new([
                 {"10.3.2.2", "1.1.1.0/24", :drop},
                 {"10.3.2.2", "2.2.2.0/24", :drop},
                 {"10.3.2.2", "3.3.3.0/24", :drop},
                 {"10.3.2.2", "4.4.4.0/24", :drop},
                 {"10.3.2.4", "4.4.4.0/24", :drop},
                 {"10.3.2.5", "5.5.5.0/24", :drop},
                 {"10.3.2.6", "6.6.6.0/24", :drop},
                 {"fd00::3:2:2", "1::/112", :drop},
                 {"fd00::3:2:2", "2::/112", :drop},
                 {"fd00::3:2:2", "3::/112", :drop},
                 {"fd00::3:2:2", "4::/112", :drop},
                 {"1.1.1.0/24", :drop},
                 {"2.2.2.0/24", :drop},
                 {"3.3.3.0/24", :drop},
                 {"4.4.4.0/24", :drop},
                 {"5.5.5.0/24", :drop}
               ])
             )

      pubkey = device.public_key
      assert {:ok, ^pubkey} = Events.delete_device(pubkey)

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

      assert MapSet.equal?(
               MapSet.new(:sys.get_state(Events.wall_pid())),
               MapSet.new([
                 {"10.3.2.4", "4.4.4.0/24", :drop},
                 {"10.3.2.5", "5.5.5.0/24", :drop},
                 {"10.3.2.6", "6.6.6.0/24", :drop},
                 {"1.1.1.0/24", :drop},
                 {"2.2.2.0/24", :drop},
                 {"3.3.3.0/24", :drop},
                 {"4.4.4.0/24", :drop},
                 {"5.5.5.0/24", :drop}
               ])
             )
    end
  end

  describe "add_rule/1 and delete_rule/1" do
    setup [:create_rule]

    test "adds rule and deletes rule", %{rule: rule} do
      :ok = Events.add_rule(rule)
      assert :sys.get_state(Events.wall_pid()) == [{"10.10.10.0/24", :drop}]

      :ok = Events.delete_rule(rule)
      assert :sys.get_state(Events.wall_pid()) == []
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

    test "sets rules" do
      :ok = Events.set_rules()

      assert :sys.get_state(Events.wall_pid()) == [
               {"1.1.1.0/24", :drop},
               {"2.2.2.0/24", :drop},
               {"3.3.3.0/24", :drop},
               {"4.4.4.0/24", :drop},
               {"5.5.5.0/24", :drop},
               {"10.3.2.4", "4.4.4.0/24", :drop},
               {"10.3.2.5", "5.5.5.0/24", :drop},
               {"10.3.2.6", "6.6.6.0/24", :drop}
             ]
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
