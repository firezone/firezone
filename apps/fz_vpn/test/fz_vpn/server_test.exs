defmodule FzVpn.ServerTest do
  use ExUnit.Case, async: true
  import FzVpn.CLI

  @single_peer [
    %{public_key: "test-pubkey", inet: "127.0.0.1/32,::1/128"}
  ]
  @many_peers [
    %{public_key: "key1", inet: "0.0.0.0/32,::1/128"},
    %{public_key: "key2", inet: "127.0.0.1/32,::1/128"},
    %{public_key: "key3", inet: "127.0.0.1/32,::1/128"},
    %{public_key: "key4", inet: "127.0.0.1/32,::1/128"}
  ]

  describe "state" do
    setup %{stubbed_config: config} do
      test_pid = :global.whereis_name(:fz_vpn_server)
      :ok = GenServer.call(test_pid, {:set_config, config})

      on_exit(fn -> cli().teardown() end)

      %{test_pid: test_pid}
    end

    @tag stubbed_config: @single_peer
    test "removes peers from config when removed", %{test_pid: test_pid} do
      GenServer.call(test_pid, {:remove_peer, "test-pubkey"})

      assert :sys.get_state(test_pid) == %{}
    end

    @tag stubbed_config: @many_peers
    test "calcs diff and sets only the diff", %{test_pid: test_pid} do
      new_peers = [%{public_key: "key5", inet: "1.1.1.1/32,::2/128"}]

      assert :sys.get_state(test_pid) == %{
               "key1" => "0.0.0.0/32,::1/128",
               "key2" => "127.0.0.1/32,::1/128",
               "key3" => "127.0.0.1/32,::1/128",
               "key4" => "127.0.0.1/32,::1/128"
             }

      GenServer.call(test_pid, {:set_config, new_peers})
      assert :sys.get_state(test_pid) == %{"key5" => "1.1.1.1/32,::2/128"}
    end
  end
end
