defmodule Portal.Repo.DynamicRepoResolverTest do
  use ExUnit.Case, async: true

  alias Portal.Repo.DynamicRepoResolver

  describe "inherit/1" do
    test "returns the repo module itself when no hierarchy exists" do
      assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo
    end

    test "returns the repo module when hierarchy has no dynamic repo set" do
      parent =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Process.put(:"$callers", [parent])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo
      after
        Process.put(:"$callers", [])
        Process.exit(parent, :kill)
      end
    end

    test "inherits dynamic repo from $callers" do
      test_pid = self()

      parent =
        spawn(fn ->
          Portal.Repo.put_dynamic_repo(Portal.Repo.Web)

          send(test_pid, :ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :ready

      Process.put(:"$callers", [parent])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo.Web
      after
        Process.put(:"$callers", [])
        Process.exit(parent, :kill)
      end
    end

    test "inherits dynamic repo from $ancestors" do
      test_pid = self()

      parent =
        spawn(fn ->
          Portal.Repo.put_dynamic_repo(Portal.Repo.Api)

          send(test_pid, :ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :ready

      Process.put(:"$ancestors", [parent])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo.Api
      after
        Process.put(:"$ancestors", [])
        Process.exit(parent, :kill)
      end
    end

    test "prefers $callers over $ancestors" do
      test_pid = self()

      caller =
        spawn(fn ->
          Portal.Repo.put_dynamic_repo(Portal.Repo.Web)
          send(test_pid, {:ready, :caller})
          receive do: (:stop -> :ok)
        end)

      ancestor =
        spawn(fn ->
          Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
          send(test_pid, {:ready, :ancestor})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:ready, :caller}
      assert_receive {:ready, :ancestor}

      Process.put(:"$callers", [caller])
      Process.put(:"$ancestors", [ancestor])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo.Web
      after
        Process.put(:"$callers", [])
        Process.put(:"$ancestors", [])
        Process.exit(caller, :kill)
        Process.exit(ancestor, :kill)
      end
    end

    test "skips dead processes in the hierarchy" do
      test_pid = self()

      dead =
        spawn(fn ->
          send(test_pid, :dead_ready)
        end)

      assert_receive :dead_ready
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      alive =
        spawn(fn ->
          Portal.Repo.put_dynamic_repo(Portal.Repo.Job)
          send(test_pid, :alive_ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :alive_ready

      Process.put(:"$callers", [dead, alive])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo.Job
      after
        Process.put(:"$callers", [])
        Process.exit(alive, :kill)
      end
    end

    test "resolves registered names in $ancestors" do
      test_pid = self()

      {:ok, pid} =
        Agent.start(
          fn ->
            Portal.Repo.put_dynamic_repo(Portal.Repo.Web)
            send(test_pid, :ready)
            :ok
          end,
          name: :"#{__MODULE__}.test_registered_name"
        )

      assert_receive :ready

      Process.put(:"$ancestors", [:"#{__MODULE__}.test_registered_name"])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo.Web
      after
        Process.put(:"$ancestors", [])
        Agent.stop(pid)
      end
    end

    test "skips unregistered names in $ancestors" do
      Process.put(:"$ancestors", [:nonexistent_process_name])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo) == Portal.Repo
      after
        Process.put(:"$ancestors", [])
      end
    end

    test "works with Portal.Repo.Replica module" do
      test_pid = self()

      parent =
        spawn(fn ->
          Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Web)
          send(test_pid, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready

      Process.put(:"$callers", [parent])

      try do
        assert DynamicRepoResolver.inherit(Portal.Repo.Replica) == Portal.Repo.Replica.Web
      after
        Process.put(:"$callers", [])
        Process.exit(parent, :kill)
      end
    end

    test "inherits through Task.async" do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Web)

      try do
        task =
          Task.async(fn ->
            DynamicRepoResolver.inherit(Portal.Repo)
          end)

        assert Task.await(task) == Portal.Repo.Web
      after
        Portal.Repo.put_dynamic_repo(Portal.Repo)
      end
    end

    test "inherits through nested Task.async" do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)

      try do
        task =
          Task.async(fn ->
            inner_task =
              Task.async(fn ->
                DynamicRepoResolver.inherit(Portal.Repo)
              end)

            Task.await(inner_task)
          end)

        assert Task.await(task) == Portal.Repo.Api
      after
        Portal.Repo.put_dynamic_repo(Portal.Repo)
      end
    end
  end
end
