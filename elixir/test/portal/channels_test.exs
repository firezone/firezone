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

    test "re-registration replaces the previous process" do
      client_id = Ecto.UUID.generate()
      parent = self()

      old_pid =
        spawn(fn ->
          Channels.register_client(client_id)
          send(parent, :registered)

          receive do
            msg -> send(parent, {:old_received, msg})
          end
        end)

      assert_receive :registered

      # New process (self) registers for the same client_id — should evict old_pid
      Channels.register_client(client_id)

      assert :ok = Channels.send_to_client(client_id, :hello)
      assert_receive :hello
      refute_receive {:old_received, :hello}

      # Cleanup
      Process.exit(old_pid, :kill)
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

    test "re-registration replaces the previous process" do
      gateway_id = Ecto.UUID.generate()
      parent = self()

      old_pid =
        spawn(fn ->
          Channels.register_gateway(gateway_id)
          send(parent, :registered)

          receive do
            msg -> send(parent, {:old_received, msg})
          end
        end)

      assert_receive :registered

      # New process (self) registers for the same gateway_id — should evict old_pid
      Channels.register_gateway(gateway_id)

      assert :ok = Channels.send_to_gateway(gateway_id, :hello)
      assert_receive :hello
      refute_receive {:old_received, :hello}

      # Cleanup
      Process.exit(old_pid, :kill)
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

  describe "handle_eviction/1" do
    test "removes the calling process from its registered group" do
      client_id = Ecto.UUID.generate()
      parent = self()
      group = {Portal.Channels, :client, client_id}

      pid =
        spawn(fn ->
          Channels.register_client(client_id)
          send(parent, :registered)

          receive do
            {:pg_group_evicted, g} ->
              Channels.handle_eviction(g)
              send(parent, :evicted)
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      assert :ok = Channels.send_to_client(client_id, :ping)

      send(pid, {:pg_group_evicted, group})
      assert_receive :evicted

      assert {:error, :not_found} = Channels.send_to_client(client_id, :ping)

      Process.exit(pid, :kill)
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
