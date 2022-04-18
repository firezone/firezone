defmodule FzVpn.ServerTest do
  use ExUnit.Case, async: true
  import FzVpn.CLI

  setup %{stubbed_config: config} do
    test_pid = :global.whereis_name(:fz_vpn_server)
    :ok = GenServer.call(test_pid, {:set_config, config})

    on_exit(fn -> cli().teardown() end)

    %{test_pid: test_pid}
  end

  describe "state" do
    @single_peer [
      %{public_key: "test-pubkey", preshared_key: "foobar", inet: "127.0.0.1/32,::1/128"}
    ]
    @many_peers [
      %{public_key: "key1", preshared_key: "foobar", inet: "0.0.0.0/32,::1/128"},
      %{public_key: "key2", preshared_key: "foobar", inet: "127.0.0.1/32,::1/128"},
      %{public_key: "key3", preshared_key: "foobar", inet: "127.0.0.1/32,::1/128"},
      %{public_key: "key4", preshared_key: "foobar", inet: "127.0.0.1/32,::1/128"}
    ]

    @tag stubbed_config: @single_peer
    test "removes peers from config when removed", %{test_pid: test_pid} do
      GenServer.call(test_pid, {:remove_peer, "test-pubkey"})

      assert :sys.get_state(test_pid) == %{}
    end

    @tag stubbed_config: @many_peers
    test "calcs diff and sets only the diff", %{test_pid: test_pid} do
      new_peers = [%{public_key: "key5", inet: "1.1.1.1/32,::2/128", preshared_key: "foobar"}]

      assert :sys.get_state(test_pid) == %{
               "key1" => %{allowed_ips: "0.0.0.0/32,::1/128", preshared_key: "foobar"},
               "key2" => %{allowed_ips: "127.0.0.1/32,::1/128", preshared_key: "foobar"},
               "key3" => %{allowed_ips: "127.0.0.1/32,::1/128", preshared_key: "foobar"},
               "key4" => %{allowed_ips: "127.0.0.1/32,::1/128", preshared_key: "foobar"}
             }

      GenServer.call(test_pid, {:set_config, new_peers})

      assert :sys.get_state(test_pid) == %{
               "key5" => %{allowed_ips: "1.1.1.1/32,::2/128", preshared_key: "foobar"}
             }
    end
  end

  describe "show commands" do
    @public_key1 "+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0="
    @public_key2 "JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY="

    @peers [
      %{public_key: @public_key1, preshared_key: nil, inet: "10.3.2.7/32,fd00::3:2:7/128"},
      %{public_key: @public_key2, preshared_key: nil, inet: "10.3.2.8/32,fd00::3:2:8/128"}
    ]

    @expected_dump_all_peers [
      %{
        public_key: @public_key1,
        preshared_key: "(none)",
        endpoint: "140.82.48.115:54248",
        allowed_ips: "10.3.2.7/32,fd00::3:2:7/128",
        latest_handshake: "1650286790",
        received_bytes: "14161600",
        transferred_bytes: "3668160",
        persistent_keepalive: "off"
      },
      %{
        public_key: @public_key2,
        preshared_key: "(none)",
        endpoint: "149.28.197.67:44491",
        allowed_ips: "10.3.2.8/32,fd00::3:2:8/128",
        latest_handshake: "1650286747",
        received_bytes: "177417128",
        transferred_bytes: "138272552",
        persistent_keepalive: "off"
      }
    ]
    @expected_dump_peer1 [
      %{
        public_key: @public_key1,
        preshared_key: "(none)",
        endpoint: "140.82.48.115:54248",
        allowed_ips: "10.3.2.7/32,fd00::3:2:7/128",
        latest_handshake: "1650286790",
        received_bytes: "14161600",
        transferred_bytes: "3668160",
        persistent_keepalive: "off"
      }
    ]
    @expected_dump_peer2 [
      %{
        public_key: @public_key2,
        preshared_key: "(none)",
        endpoint: "149.28.197.67:44491",
        allowed_ips: "10.3.2.8/32,fd00::3:2:8/128",
        latest_handshake: "1650286747",
        received_bytes: "177417128",
        transferred_bytes: "138272552",
        persistent_keepalive: "off"
      }
    ]

    @tag stubbed_config: @peers
    test "dump multiple", %{test_pid: test_pid} do
      public_keys = [@public_key1, @public_key2]
      assert {:ok, dump} = GenServer.call(test_pid, {:show_dump, public_keys})
      assert dump == @expected_dump_all_peers
    end

    @tag stubbed_config: @peers
    test "dump peer1", %{test_pid: test_pid} do
      assert {:ok, dump} = GenServer.call(test_pid, {:show_dump, [@public_key1]})
      assert dump == @expected_dump_peer1
    end

    @tag stubbed_config: @peers
    test "dump peer2", %{test_pid: test_pid} do
      assert {:ok, dump} = GenServer.call(test_pid, {:show_dump, [@public_key2]})
      assert dump == @expected_dump_peer2
    end
  end
end
