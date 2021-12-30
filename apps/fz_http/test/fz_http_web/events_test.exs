defmodule FzHttpWeb.EventsTest do
  @moduledoc """
  XXX: Use start_supervised! somehow here to allow async tests.
  """
  use FzHttp.DataCase, async: false

  alias FzHttp.Devices
  alias FzHttpWeb.Events

  # XXX: Not needed with start_supervised!
  setup do
    on_exit(fn ->
      :sys.replace_state(Events.vpn_pid(), fn _state -> %{} end)
      :sys.replace_state(Events.wall_pid(), fn _state -> [] end)
    end)
  end

  describe "create_device/0" do
    test "receives info to create device" do
      assert {:ok, _privkey, _pubkey, _server_pubkey} = Events.create_device()
    end
  end

  describe "update_device/1" do
    setup [:create_device]

    test "adds device to peer config", %{device: device} do
      assert :ok == Events.update_device(device)

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key =>
                 "#{Devices.ipv4_address(device)},#{Devices.ipv6_address(device)}"
             }
    end
  end

  describe "device_update/1" do
    setup [:create_device]

    test "updates peer config", %{device: device} do
      assert :ok = Events.update_device(device)

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key =>
                 "#{Devices.ipv4_address(device)},#{Devices.ipv6_address(device)}"
             }
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
               Map.new(Devices.to_peer_list(), fn peer -> {peer.public_key, peer.inet} end)
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
               {"5.5.5.0/24", :drop}
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
