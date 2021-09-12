defmodule FzVpn.ServerTest do
  use ExUnit.Case, async: true
  import FzVpn.CLI

  @empty %{}
  @single_peer %{"test-pubkey" => "127.0.0.1"}

  describe "state" do
    setup %{stubbed_config: config} do
      test_pid = :global.whereis_name(:fz_vpn_server)
      :ok = GenServer.call(test_pid, {:set_config, config})

      on_exit(fn -> cli().teardown() end)

      %{test_pid: test_pid}
    end

    @tag stubbed_config: @empty
    test "generates new peer when requested", %{test_pid: test_pid} do
      assert {:ok, _, _, _} = GenServer.call(test_pid, :create_device)
      # Peers aren't added to config until device is successfully created

      assert :sys.get_state(test_pid) == %{}
    end

    @tag stubbed_config: @single_peer
    test "removes peers from config when removed", %{test_pid: test_pid} do
      GenServer.call(test_pid, {:delete_device, "test-pubkey"})

      assert :sys.get_state(test_pid) == %{}
    end
  end
end
