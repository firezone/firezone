defmodule FgVpn.ServerTest do
  use ExUnit.Case, async: true
  alias FgVpn.{Config, Peer, Server}
  import FgVpn.CLI

  @empty %Config{}
  @single_peer %Config{peers: MapSet.new([%Peer{public_key: "test-pubkey"}])}

  describe "state" do
    setup %{stubbed_config: config} do
      test_pid = start_supervised!(Server)

      :ok = GenServer.call(test_pid, {:set_config, config})

      on_exit(fn -> cli().teardown() end)

      %{test_pid: test_pid}
    end

    @tag stubbed_config: @empty
    test "generates new peer when requested", %{test_pid: test_pid} do
      assert {:ok, _, _, _, _} = GenServer.call(test_pid, :create_device)
      assert [_peer] = MapSet.to_list(:sys.get_state(test_pid).peers)
    end

    @tag stubbed_config: @single_peer
    test "removes peers from config when removed", %{test_pid: test_pid} do
      GenServer.call(test_pid, {:delete_device, "test-pubkey"})
      assert MapSet.to_list(:sys.get_state(test_pid).peers) == []
    end
  end
end
