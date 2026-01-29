defmodule Portal.Replication.ManagerTest do
  use ExUnit.Case, async: true

  alias Portal.Replication.Manager

  describe "terminate/2" do
    test "sends :shutdown to connection_pid when present" do
      # Create a simple process that will receive the :shutdown message
      test_pid = self()

      connection_pid =
        spawn(fn ->
          receive do
            :shutdown -> send(test_pid, :shutdown_received)
          end
        end)

      state = %{connection_pid: connection_pid, connection_module: SomeModule, retries: 0}

      assert Manager.terminate(:shutdown, state) == :ok
      assert_receive :shutdown_received, 100
    end

    test "returns :ok when connection_pid is nil" do
      state = %{connection_pid: nil, connection_module: SomeModule, retries: 0}
      assert Manager.terminate(:shutdown, state) == :ok
    end
  end
end
