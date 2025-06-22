defmodule Domain.ChangeLogs.ReplicationConnectionTest do
  use Domain.DataCase, async: true

  import ExUnit.CaptureLog
  import Ecto.Query
  import Domain.ChangeLogs.ReplicationConnection
  alias Domain.ChangeLogs.ChangeLog
  alias Domain.Repo

  setup do
    account = Fixtures.Accounts.create_account()
    %{account: account}
  end

  describe "on_insert/2" do
    test "ignores flows table - no record created" do
      table = "flows"
      data = %{"id" => 1, "name" => "test flow"}

      initial_count = Repo.aggregate(ChangeLog, :count, :id)

      assert :ok = on_insert(table, data)

      # No record should be created for flows
      final_count = Repo.aggregate(ChangeLog, :count, :id)
      assert final_count == initial_count
    end

    test "creates change log record for non-flows tables", %{account: account} do
      table = "accounts"
      data = %{"id" => account.id, "name" => "test account"}

      assert :ok = on_insert(table, data)

      # Verify the record was created
      change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

      assert change_log.op == :insert
      assert change_log.table == table
      assert change_log.old_data == nil
      assert change_log.data == data
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end

    test "creates records for different table types", %{account: account} do
      test_cases = [
        {"accounts", %{"id" => account.id, "name" => "test account"}},
        {"resources",
         %{"id" => Ecto.UUID.generate(), "name" => "test resource", "account_id" => account.id}},
        {"policies",
         %{"id" => Ecto.UUID.generate(), "name" => "test policy", "account_id" => account.id}},
        {"actors",
         %{"id" => Ecto.UUID.generate(), "name" => "test actor", "account_id" => account.id}}
      ]

      for {table, data} <- test_cases do
        initial_count = Repo.aggregate(ChangeLog, :count, :id)

        assert :ok = on_insert(table, data)

        final_count = Repo.aggregate(ChangeLog, :count, :id)
        assert final_count == initial_count + 1

        change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

        assert change_log.op == :insert
        assert change_log.table == table
        assert change_log.old_data == nil
        assert change_log.data == data
        assert change_log.vsn == 0
        assert change_log.account_id == account.id
      end
    end
  end

  describe "on_update/3" do
    test "ignores flows table - no record created" do
      table = "flows"
      old_data = %{"id" => 1, "name" => "old flow"}
      data = %{"id" => 1, "name" => "new flow"}

      initial_count = Repo.aggregate(ChangeLog, :count, :id)

      assert :ok = on_update(table, old_data, data)

      # No record should be created for flows
      final_count = Repo.aggregate(ChangeLog, :count, :id)
      assert final_count == initial_count
    end

    test "creates change log record for non-flows tables", %{account: account} do
      table = "accounts"
      old_data = %{"id" => account.id, "name" => "old name"}
      data = %{"id" => account.id, "name" => "new name"}

      assert :ok = on_update(table, old_data, data)

      # Verify the record was created
      change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

      assert change_log.op == :update
      assert change_log.table == table
      assert change_log.old_data == old_data
      assert change_log.data == data
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end

    test "handles complex data structures", %{account: account} do
      table = "resources"
      resource_id = Ecto.UUID.generate()

      old_data = %{
        "id" => resource_id,
        "name" => "old name",
        "account_id" => account.id,
        "settings" => %{"theme" => "dark", "notifications" => true}
      }

      data = %{
        "id" => resource_id,
        "name" => "new name",
        "account_id" => account.id,
        "settings" => %{"theme" => "light", "notifications" => false},
        "tags" => ["updated", "important"]
      }

      assert :ok = on_update(table, old_data, data)

      change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

      assert change_log.op == :update
      assert change_log.table == table
      assert change_log.old_data == old_data
      assert change_log.data == data
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end
  end

  describe "on_delete/2" do
    test "ignores flows table - no record created" do
      table = "flows"
      old_data = %{"id" => 1, "name" => "deleted flow"}

      initial_count = Repo.aggregate(ChangeLog, :count, :id)

      assert :ok = on_delete(table, old_data)

      # No record should be created for flows
      final_count = Repo.aggregate(ChangeLog, :count, :id)
      assert final_count == initial_count
    end

    test "creates change log record for non-flows tables", %{account: account} do
      table = "accounts"
      old_data = %{"id" => account.id, "name" => "deleted account"}

      assert :ok = on_delete(table, old_data)

      # Verify the record was created
      change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

      assert change_log.op == :delete
      assert change_log.table == table
      assert change_log.old_data == old_data
      assert change_log.data == nil
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end

    test "handles various data types in old_data", %{account: account} do
      table = "resources"
      resource_id = Ecto.UUID.generate()

      old_data = %{
        "id" => resource_id,
        "name" => "complex resource",
        "account_id" => account.id,
        "metadata" => %{
          "created_by" => "system",
          "permissions" => ["read", "write"],
          "config" => %{"timeout" => 30, "retries" => 3}
        },
        "active" => true,
        "count" => 42
      }

      assert :ok = on_delete(table, old_data)

      change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

      assert change_log.op == :delete
      assert change_log.table == table
      assert change_log.old_data == old_data
      assert change_log.data == nil
      assert change_log.vsn == 0
      assert change_log.account_id == account.id
    end
  end

  describe "error handling" do
    test "handles foreign key errors gracefully" do
      # Create a change log entry that references a non-existent account
      table = "resources"
      # Non-existent account_id
      data = %{"id" => Ecto.UUID.generate(), "account_id" => Ecto.UUID.generate()}

      initial_count = Repo.aggregate(ChangeLog, :count, :id)

      # Should return :ok even if foreign key constraint fails
      assert :ok = on_insert(table, data)

      # No record should be created due to foreign key error
      final_count = Repo.aggregate(ChangeLog, :count, :id)
      assert final_count == initial_count
    end

    test "logs and returns :error for non-foreign-key validation errors", %{account: account} do
      # Test with invalid data that would cause validation errors (not foreign key)
      table = "accounts"
      # Missing required fields but valid FK
      data = %{"account_id" => account.id}

      initial_count = Repo.aggregate(ChangeLog, :count, :id)

      log_output =
        capture_log(fn ->
          assert :error = on_insert(table, data)
        end)

      # Should log the error
      assert log_output =~ "Failed to create change log"

      # No record should be created
      final_count = Repo.aggregate(ChangeLog, :count, :id)
      assert final_count == initial_count
    end
  end

  describe "data integrity" do
    test "preserves exact data structures", %{account: account} do
      table = "policies"
      policy_id = Ecto.UUID.generate()

      # Test with various data types
      complex_data = %{
        "id" => policy_id,
        "account_id" => account.id,
        "string_field" => "test string",
        "integer_field" => 42,
        "boolean_field" => true,
        "null_field" => nil,
        "array_field" => [1, "two", %{"three" => 3}],
        "nested_object" => %{
          "level1" => %{
            "level2" => %{
              "deep_value" => "preserved"
            }
          }
        }
      }

      assert :ok = on_insert(table, complex_data)

      change_log = Repo.one!(from cl in ChangeLog, order_by: [desc: cl.inserted_at], limit: 1)

      # Data should be preserved exactly as provided
      assert change_log.data == complex_data
      assert change_log.op == :insert
      assert change_log.table == table
      assert change_log.account_id == account.id
    end

    test "tracks operation sequence correctly", %{account: account} do
      table = "accounts"
      initial_data = %{"id" => account.id, "name" => "initial"}
      updated_data = %{"id" => account.id, "name" => "updated"}

      # Insert
      assert :ok = on_insert(table, initial_data)

      # Update
      assert :ok = on_update(table, initial_data, updated_data)

      # Delete
      assert :ok = on_delete(table, updated_data)

      # Get the three most recent records in reverse chronological order
      logs =
        Repo.all(
          from cl in ChangeLog,
            where: cl.account_id == ^account.id,
            order_by: [desc: cl.inserted_at],
            limit: 3
        )

      # Should have 3 records (delete, update, insert in that order)
      assert length(logs) >= 3
      [delete_log, update_log, insert_log] = Enum.take(logs, 3)

      # Verify sequence (most recent first)
      assert delete_log.op == :delete
      assert delete_log.old_data == updated_data
      assert delete_log.data == nil
      assert delete_log.account_id == account.id

      assert update_log.op == :update
      assert update_log.old_data == initial_data
      assert update_log.data == updated_data
      assert update_log.account_id == account.id

      assert insert_log.op == :insert
      assert insert_log.old_data == nil
      assert insert_log.data == initial_data
      assert insert_log.account_id == account.id

      # All should have same version
      assert insert_log.vsn == 0
      assert update_log.vsn == 0
      assert delete_log.vsn == 0
    end
  end

  describe "flows table comprehensive test" do
    test "flows table never creates records regardless of operation or data" do
      initial_count = Repo.aggregate(ChangeLog, :count, :id)

      # Test various data shapes and operations
      test_data_sets = [
        %{},
        %{"id" => 1},
        %{"complex" => %{"nested" => ["data", 1, true, nil]}},
        nil
      ]

      for data <- test_data_sets do
        assert :ok = on_insert("flows", data)
        assert :ok = on_update("flows", data, data)
        assert :ok = on_delete("flows", data)
      end

      # No records should have been created
      final_count = Repo.aggregate(ChangeLog, :count, :id)
      assert final_count == initial_count
    end
  end
end
