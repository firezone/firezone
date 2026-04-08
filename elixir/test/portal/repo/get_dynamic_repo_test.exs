defmodule Portal.Repo.GetDynamicRepoTest do
  use ExUnit.Case, async: true

  describe "Portal.Repo.get_dynamic_repo/0" do
    test "returns Portal.Repo when no dynamic repo is set and no hierarchy" do
      assert Portal.Repo.get_dynamic_repo() == Portal.Repo
    end

    test "returns explicitly set dynamic repo" do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Web)

      try do
        assert Portal.Repo.get_dynamic_repo() == Portal.Repo.Web
      after
        Portal.Repo.put_dynamic_repo(Portal.Repo)
      end
    end

    test "inherits from parent process via $callers" do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)

      try do
        task =
          Task.async(fn ->
            Portal.Repo.get_dynamic_repo()
          end)

        assert Task.await(task) == Portal.Repo.Api
      after
        Portal.Repo.put_dynamic_repo(Portal.Repo)
      end
    end

    test "caches inherited repo in child process" do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Job)

      try do
        task =
          Task.async(fn ->
            Portal.Repo.get_dynamic_repo()

            assert Process.get({Portal.Repo, :dynamic_repo}) == Portal.Repo.Job
          end)

        Task.await(task)
      after
        Portal.Repo.put_dynamic_repo(Portal.Repo)
      end
    end

    test "does not cache when falling back to self" do
      task =
        Task.async(fn ->
          Portal.Repo.get_dynamic_repo()

          refute Process.get({Portal.Repo, :dynamic_repo})
        end)

      Task.await(task)
    end
  end

  describe "Portal.Repo.Replica.get_dynamic_repo/0" do
    test "returns Portal.Repo.Replica when no dynamic repo is set" do
      assert Portal.Repo.Replica.get_dynamic_repo() == Portal.Repo.Replica
    end

    test "returns explicitly set dynamic repo" do
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Web)

      try do
        assert Portal.Repo.Replica.get_dynamic_repo() == Portal.Repo.Replica.Web
      after
        Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica)
      end
    end

    test "inherits from parent process via $callers" do
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Api)

      try do
        task =
          Task.async(fn ->
            Portal.Repo.Replica.get_dynamic_repo()
          end)

        assert Task.await(task) == Portal.Repo.Replica.Api
      after
        Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica)
      end
    end
  end
end
