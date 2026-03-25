defmodule Portal.PGTest do
  use ExUnit.Case, async: true
  alias Portal.PG

  setup do
    scope = :"Portal.PG.#{inspect(make_ref())}"
    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})
    Portal.Config.put_env_override(:portal, :pg_scope, scope)
    {:ok, scope: scope}
  end

  describe "register_client/1 and send_to_client/2" do
    test "delivers message to a registered client process" do
      client_id = Ecto.UUID.generate()
      PG.register(client_id)

      assert :ok = PG.deliver(client_id, :hello)
      assert_receive :hello
    end

    test "re-registration sends :disconnect to the previous process", %{scope: scope} do
      client_id = Ecto.UUID.generate()
      parent = self()

      old_pid =
        spawn(fn ->
          Portal.Config.put_env_override(:portal, :pg_scope, scope)
          PG.register(client_id)
          send(parent, :registered)

          receive do
            msg -> send(parent, {:old_received, msg})
          end
        end)

      assert_receive :registered

      # New process (self) registers for the same client_id — should evict old_pid
      PG.register(client_id)

      assert_receive {:old_received, :disconnect}

      assert :ok = PG.deliver(client_id, :hello)
      assert_receive :hello

      # Cleanup
      Process.exit(old_pid, :kill)
    end

    test "returns {:error, :not_found} when no process is registered" do
      client_id = Ecto.UUID.generate()
      assert {:error, :not_found} = PG.deliver(client_id, :hello)
    end
  end

  describe "register_gateway/1 and send_to_gateway/2" do
    test "delivers message to a registered gateway process" do
      gateway_id = Ecto.UUID.generate()
      PG.register(gateway_id)

      assert :ok = PG.deliver(gateway_id, :hello)
      assert_receive :hello
    end

    test "re-registration sends :disconnect to the previous process", %{scope: scope} do
      gateway_id = Ecto.UUID.generate()
      parent = self()

      old_pid =
        spawn(fn ->
          Portal.Config.put_env_override(:portal, :pg_scope, scope)
          PG.register(gateway_id)
          send(parent, :registered)

          receive do
            msg -> send(parent, {:old_received, msg})
          end
        end)

      assert_receive :registered

      # New process (self) registers for the same gateway_id — should evict old_pid
      PG.register(gateway_id)

      assert_receive {:old_received, :disconnect}

      assert :ok = PG.deliver(gateway_id, :hello)
      assert_receive :hello

      # Cleanup
      Process.exit(old_pid, :kill)
    end

    test "returns {:error, :not_found} when no process is registered" do
      gateway_id = Ecto.UUID.generate()
      assert {:error, :not_found} = PG.deliver(gateway_id, :hello)
    end
  end

  describe "process exit cleanup" do
    test "removes process from group when it exits", %{scope: scope} do
      client_id = Ecto.UUID.generate()
      parent = self()

      pid =
        spawn(fn ->
          Portal.Config.put_env_override(:portal, :pg_scope, scope)
          PG.register(client_id)
          send(parent, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered

      # Confirm delivery works while process is alive
      assert :ok = PG.deliver(client_id, :ping)

      # Stop the process and wait for :pg to clean up
      Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, _, :process, ^pid, :normal}

      # :pg cleanup is async; give it a moment
      Process.sleep(50)

      assert {:error, :not_found} = PG.deliver(client_id, :ping)
    end
  end

  describe "register_token/1 and send_to_token/2" do
    test "delivers message to a registered process" do
      token_id = Ecto.UUID.generate()
      PG.register(token_id)

      assert :ok = PG.deliver(token_id, :hello)
      assert_receive :hello
    end

    test "returns {:error, :not_found} when no process is registered" do
      token_id = Ecto.UUID.generate()
      assert {:error, :not_found} = PG.deliver(token_id, :hello)
    end
  end

  describe "join/1 (credential/token shared by multiple clients)" do
    test "multiple processes can join the same key without disconnecting each other", %{
      scope: scope
    } do
      credential_id = Ecto.UUID.generate()
      parent = self()

      pids =
        for i <- 1..10 do
          spawn(fn ->
            Portal.Config.put_env_override(:portal, :pg_scope, scope)
            PG.join(credential_id)
            send(parent, {:joined, i})

            receive do
              msg -> send(parent, {:received, i, msg})
            end
          end)
        end

      for i <- 1..10, do: assert_receive({:joined, ^i})

      # All 10 processes should receive the message — none were disconnected
      assert :ok = PG.deliver(credential_id, :hello)

      for i <- 1..10, do: assert_receive({:received, ^i, :hello})

      Enum.each(pids, &Process.exit(&1, :kill))
    end

    test "join does not disconnect processes registered with register/1", %{scope: scope} do
      key = Ecto.UUID.generate()
      parent = self()

      pid =
        spawn(fn ->
          Portal.Config.put_env_override(:portal, :pg_scope, scope)
          PG.register(key)
          send(parent, :registered)

          receive do
            msg -> send(parent, {:first, msg})
          end
        end)

      assert_receive :registered

      # join should NOT send :disconnect to the existing process
      PG.join(key)

      # Deliver should reach both the registered process and self
      assert :ok = PG.deliver(key, :hello)
      assert_receive {:first, :hello}
      assert_receive :hello

      Process.exit(pid, :kill)
    end

    test "register/1 disconnects joined processes but join/1 does not", %{scope: scope} do
      key = Ecto.UUID.generate()
      parent = self()

      joined_pid =
        spawn(fn ->
          Portal.Config.put_env_override(:portal, :pg_scope, scope)
          PG.join(key)
          send(parent, :joined)

          receive do
            msg -> send(parent, {:joined_received, msg})
          end
        end)

      assert_receive :joined

      # register/1 should disconnect the joined process
      PG.register(key)

      assert_receive {:joined_received, :disconnect}

      Process.exit(joined_pid, :kill)
    end
  end

  describe "scope_pid/0" do
    test "returns the pid of the running pg scope" do
      assert is_pid(PG.scope_pid())
    end
  end

  describe "noproc handling" do
    test "returns {:error, :not_found} when the pg scope is not running" do
      client_id = Ecto.UUID.generate()
      PG.register(client_id)

      scope_pid = PG.scope_pid()
      ref = Process.monitor(scope_pid)
      Process.exit(scope_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^scope_pid, :killed}

      assert {:error, :not_found} = PG.deliver(client_id, :hello)
    end
  end

  describe "deliver/2 with structured messages" do
    test "delivers a reject_access tuple to a registered gateway" do
      gateway_id = Ecto.UUID.generate()
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      PG.register(gateway_id)

      assert :ok = PG.deliver(gateway_id, {:reject_access, client_id, resource_id})
      assert_receive {:reject_access, ^client_id, ^resource_id}
    end

    test "returns {:error, :not_found} when no process is registered" do
      gateway_id = Ecto.UUID.generate()
      assert {:error, :not_found} = PG.deliver(gateway_id, {:reject_access, "c", "r"})
    end
  end
end
