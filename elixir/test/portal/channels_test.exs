defmodule Portal.ChannelsTest do
  use ExUnit.Case, async: true
  alias Portal.Channels

  describe "register_client/1 and send_to_client/2" do
    test "delivers message to a registered client process" do
      client_id = Ecto.UUID.generate()
      Channels.register_client(client_id)

      assert :ok = Channels.send_to_client(client_id, :hello)
      assert_receive :hello
    end

    test "delivers message to multiple registered processes" do
      client_id = Ecto.UUID.generate()
      parent = self()

      pids =
        for _ <- 1..3 do
          spawn(fn ->
            Channels.register_client(client_id)
            send(parent, {:registered, self()})

            receive do
              msg -> send(parent, {:received, self(), msg})
            end
          end)
        end

      for pid <- pids, do: assert_receive({:registered, ^pid})

      assert :ok = Channels.send_to_client(client_id, :broadcast)

      for pid <- pids, do: assert_receive({:received, ^pid, :broadcast})
    end

    test "returns {:error, :not_found} when no process is registered" do
      client_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Channels.send_to_client(client_id, :hello)
    end
  end

  describe "register_gateway/1 and send_to_gateway/2" do
    test "delivers message to a registered gateway process" do
      gateway_id = Ecto.UUID.generate()
      Channels.register_gateway(gateway_id)

      assert :ok = Channels.send_to_gateway(gateway_id, :hello)
      assert_receive :hello
    end

    test "returns {:error, :not_found} when no process is registered" do
      gateway_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Channels.send_to_gateway(gateway_id, :hello)
    end
  end

  describe "process exit cleanup" do
    test "removes process from group when it exits" do
      client_id = Ecto.UUID.generate()
      parent = self()

      pid =
        spawn(fn ->
          Channels.register_client(client_id)
          send(parent, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered

      # Confirm delivery works while process is alive
      assert :ok = Channels.send_to_client(client_id, :ping)

      # Stop the process and wait for :pg to clean up
      Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, _, :process, ^pid, :normal}

      # :pg cleanup is async; give it a moment
      Process.sleep(50)

      assert {:error, :not_found} = Channels.send_to_client(client_id, :ping)
    end
  end

  describe "reject_access/3" do
    test "sends reject_access message to the gateway" do
      gateway_id = Ecto.UUID.generate()
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      Channels.register_gateway(gateway_id)

      assert :ok = Channels.reject_access(gateway_id, client_id, resource_id)
      assert_receive {:reject_access, ^client_id, ^resource_id}
    end

    test "returns {:error, :not_found} when gateway is not registered" do
      gateway_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Channels.reject_access(gateway_id, "c", "r")
    end
  end
end
