defmodule Portal.Repo.ReplicaTest do
  use Portal.DataCase, async: true

  alias Portal.Repo.Replica

  describe "read operations" do
    # Note: Due to sandbox isolation, data inserted via Portal.Repo is not visible
    # to Portal.Repo.Replica in tests. These tests verify the read functions exist
    # and can be called without error.

    test "all/1 returns a list" do
      result = Replica.all(Portal.Account)
      assert is_list(result)
    end

    test "get/2 returns nil for non-existent record" do
      result = Replica.get(Portal.Account, Ecto.UUID.generate())
      assert is_nil(result)
    end

    test "get!/2 raises for non-existent record" do
      assert_raise Ecto.NoResultsError, fn ->
        Replica.get!(Portal.Account, Ecto.UUID.generate())
      end
    end

    test "one/1 returns nil for empty query" do
      import Ecto.Query
      query = from(a in Portal.Account, where: a.id == ^Ecto.UUID.generate())

      result = Replica.one(query)
      assert is_nil(result)
    end

    test "aggregate/2 returns a count" do
      count = Replica.aggregate(Portal.Account, :count)
      assert is_integer(count)
      assert count >= 0
    end

    test "exists?/1 returns false for non-matching query" do
      import Ecto.Query
      query = from(a in Portal.Account, where: a.id == ^Ecto.UUID.generate())

      refute Replica.exists?(query)
    end

    test "preload/2 works on structs" do
      # Create a struct manually to test preload function exists
      account = %Portal.Account{id: Ecto.UUID.generate(), actors: %Ecto.Association.NotLoaded{}}

      # preload should work even if the underlying query returns nothing
      # (the struct will keep the NotLoaded marker if no DB records found)
      result = Replica.preload(account, :actors)
      assert result.id == account.id
    end
  end

  describe "write operations are not available" do
    # read_only: true in Ecto.Repo means write functions are not defined
    # This is the key behavior we want to verify

    test "insert/2 is not defined" do
      refute function_exported?(Replica, :insert, 2)
    end

    test "insert!/2 is not defined" do
      refute function_exported?(Replica, :insert!, 2)
    end

    test "update/2 is not defined" do
      refute function_exported?(Replica, :update, 2)
    end

    test "update!/2 is not defined" do
      refute function_exported?(Replica, :update!, 2)
    end

    test "delete/2 is not defined" do
      refute function_exported?(Replica, :delete, 2)
    end

    test "delete!/2 is not defined" do
      refute function_exported?(Replica, :delete!, 2)
    end

    test "insert_all/3 is not defined" do
      refute function_exported?(Replica, :insert_all, 3)
    end

    test "update_all/3 is not defined" do
      refute function_exported?(Replica, :update_all, 3)
    end

    test "delete_all/2 is not defined" do
      refute function_exported?(Replica, :delete_all, 2)
    end
  end

  describe "configuration" do
    test "is configured as a valid repo" do
      assert Replica.get_dynamic_repo() == Replica
    end

    test "returns correct config" do
      config = Replica.config()

      assert Keyword.has_key?(config, :database)
      assert Keyword.has_key?(config, :hostname) or Keyword.has_key?(config, :socket_dir)
      assert config[:database] == "firezone_test"
    end

    test "uses sandbox pool in test environment" do
      config = Replica.config()
      assert config[:pool] == Ecto.Adapters.SQL.Sandbox
    end
  end
end
