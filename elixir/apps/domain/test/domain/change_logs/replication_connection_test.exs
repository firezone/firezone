defmodule Domain.ChangeLogs.ReplicationConnectionTest do
  use Domain.DataCase, async: true

  import Ecto.Query
  import Domain.ChangeLogs.ReplicationConnection
  alias Domain.ChangeLogs.ChangeLog
  alias Domain.Repo

  setup do
    account = Fixtures.Accounts.create_account()
    %{account: account}
  end

  describe "on_insert/4" do
    test "adds insert operation to flush buffer", %{account: account} do
      table = "accounts"
      data = %{"id" => account.id, "name" => "test account"}
      lsn = 12345

      initial_state = %{flush_buffer: []}

      result_state = on_insert(lsn, table, data, initial_state)

      assert length(result_state.flush_buffer) == 1
      [attrs] = result_state.flush_buffer

      assert attrs.lsn == lsn
      assert attrs.table == table
      assert attrs.op == :insert
      assert attrs.data == data
      assert attrs.old_data == nil
      assert attrs.vsn == 0
    end

    test "preserves existing buffer items", %{account: account} do
      existing_item = %{
        lsn: 100,
        table: "other_table",
        op: :update,
        data: %{"id" => "existing"},
        old_data: nil,
        vsn: 0
      }

      initial_state = %{flush_buffer: [existing_item]}

      result_state = on_insert(101, "accounts", %{"id" => account.id}, initial_state)

      assert length(result_state.flush_buffer) == 2
      [new_item, old_item] = result_state.flush_buffer

      # New item is prepended
      assert new_item.lsn == 101
      assert new_item.op == :insert

      # Old item is preserved
      assert old_item == existing_item
    end

    test "handles complex data structures", %{account: account} do
      complex_data = %{
        "id" => account.id,
        "account_id" => account.id,
        "nested" => %{"key" => "value", "array" => [1, 2, 3]},
        "null_field" => nil,
        "boolean" => true
      }

      state = %{flush_buffer: []}
      result_state = on_insert(200, "resources", complex_data, state)

      [attrs] = result_state.flush_buffer
      assert attrs.data == complex_data
    end
  end

  describe "on_update/5" do
    test "adds update operation to flush buffer", %{account: account} do
      table = "accounts"
      old_data = %{"id" => account.id, "name" => "old name"}
      data = %{"id" => account.id, "name" => "new name"}
      lsn = 12346

      initial_state = %{flush_buffer: []}

      result_state = on_update(lsn, table, old_data, data, initial_state)

      assert length(result_state.flush_buffer) == 1
      [attrs] = result_state.flush_buffer

      assert attrs.lsn == lsn
      assert attrs.table == table
      assert attrs.op == :update
      assert attrs.data == data
      assert attrs.old_data == old_data
      assert attrs.vsn == 0
    end

    test "handles complex data changes", %{account: account} do
      old_data = %{
        "id" => account.id,
        "settings" => %{"theme" => "dark"},
        "tags" => ["old"]
      }

      new_data = %{
        "id" => account.id,
        "settings" => %{"theme" => "light", "language" => "en"},
        "tags" => ["new", "updated"]
      }

      state = %{flush_buffer: []}
      result_state = on_update(300, "accounts", old_data, new_data, state)

      [attrs] = result_state.flush_buffer
      assert attrs.old_data == old_data
      assert attrs.data == new_data
    end
  end

  describe "on_delete/4" do
    test "adds delete operation to flush buffer for non-soft-deleted records", %{account: account} do
      table = "accounts"
      old_data = %{"id" => account.id, "name" => "deleted account", "deleted_at" => nil}
      lsn = 12347

      initial_state = %{flush_buffer: []}

      result_state = on_delete(lsn, table, old_data, initial_state)

      assert length(result_state.flush_buffer) == 1
      [attrs] = result_state.flush_buffer

      assert attrs.lsn == lsn
      assert attrs.table == table
      assert attrs.op == :delete
      assert attrs.data == nil
      assert attrs.old_data == old_data
      assert attrs.vsn == 0
    end

    test "ignores soft-deleted records", %{account: account} do
      table = "accounts"

      old_data = %{
        "id" => account.id,
        "name" => "soft deleted",
        "deleted_at" => "2024-01-01T00:00:00Z"
      }

      lsn = 12348

      initial_state = %{flush_buffer: []}

      result_state = on_delete(lsn, table, old_data, initial_state)

      # Buffer should remain unchanged
      assert length(result_state.flush_buffer) == 0
      assert result_state == initial_state
    end

    test "processes record without deleted_at field", %{account: account} do
      old_data = %{"id" => account.id, "name" => "no deleted_at field"}

      state = %{flush_buffer: []}
      result_state = on_delete(400, "accounts", old_data, state)

      assert length(result_state.flush_buffer) == 1
      [attrs] = result_state.flush_buffer
      assert attrs.op == :delete
    end
  end

  describe "multiple operations and buffer accumulation" do
    test "operations accumulate in flush buffer correctly", %{account: account} do
      initial_state = %{flush_buffer: []}

      # Insert
      state1 = on_insert(100, "accounts", %{"id" => account.id, "name" => "test"}, initial_state)
      assert length(state1.flush_buffer) == 1

      # Update
      state2 =
        on_update(
          101,
          "accounts",
          %{"id" => account.id, "name" => "test"},
          %{"id" => account.id, "name" => "updated"},
          state1
        )

      assert length(state2.flush_buffer) == 2

      # Delete (non-soft)
      state3 = on_delete(102, "accounts", %{"id" => account.id, "name" => "updated"}, state2)
      assert length(state3.flush_buffer) == 3

      # Verify order (most recent first since we prepend)
      [delete_attrs, update_attrs, insert_attrs] = state3.flush_buffer
      assert delete_attrs.lsn == 102
      assert delete_attrs.op == :delete
      assert update_attrs.lsn == 101
      assert update_attrs.op == :update
      assert insert_attrs.lsn == 100
      assert insert_attrs.op == :insert
    end

    test "mixed operations with soft deletes", %{account: account} do
      state = %{flush_buffer: []}

      # Regular insert
      state1 = on_insert(100, "accounts", %{"id" => account.id, "name" => "test"}, state)

      # Regular update
      state2 =
        on_update(
          101,
          "accounts",
          %{"id" => account.id, "name" => "test"},
          %{"id" => account.id, "name" => "updated"},
          state1
        )

      # Soft delete (should be ignored)
      state3 =
        on_delete(
          102,
          "accounts",
          %{"id" => account.id, "name" => "updated", "deleted_at" => "2024-01-01T00:00:00Z"},
          state2
        )

      # Hard delete (should be included)
      state4 =
        on_delete(
          103,
          "accounts",
          %{"id" => account.id, "name" => "updated", "deleted_at" => nil},
          state3
        )

      # Should have 3 operations: insert, update, hard delete (soft delete ignored)
      assert length(state4.flush_buffer) == 3

      # Verify operations (in reverse order since we prepend)
      [hard_delete, update, insert] = state4.flush_buffer
      assert hard_delete.op == :delete
      assert hard_delete.lsn == 103
      assert update.op == :update
      assert update.lsn == 101
      assert insert.op == :insert
      assert insert.lsn == 100
    end
  end

  describe "on_flush/1" do
    test "handles empty flush buffer" do
      state = %{flush_buffer: []}

      result_state = on_flush(state)

      assert result_state == state
    end

    test "successfully flushes buffer and clears it", %{account: account} do
      # Create valid change log data
      attrs1 = %{
        lsn: 100,
        table: "accounts",
        op: :insert,
        data: %{"id" => account.id, "name" => "test1"},
        old_data: nil,
        vsn: 0
      }

      attrs2 = %{
        lsn: 101,
        table: "accounts",
        op: :update,
        data: %{"id" => account.id, "name" => "test2"},
        old_data: %{"id" => account.id, "name" => "test1"},
        vsn: 0
      }

      state = %{flush_buffer: [attrs2, attrs1], last_flushed_lsn: 99}

      result_state = on_flush(state)

      assert result_state.flush_buffer == []
      # Should be the highest LSN
      assert result_state.last_flushed_lsn == 101

      # Verify actual records were created in database
      change_logs =
        Repo.all(from cl in ChangeLog, where: cl.lsn in [100, 101], order_by: cl.lsn)

      assert length(change_logs) == 2

      [log1, log2] = change_logs
      assert log1.lsn == 100
      assert log1.op == :insert
      assert log2.lsn == 101
      assert log2.op == :update
    end

    test "handles partial bulk insert failures gracefully", %{account: account} do
      # Create a mix of valid and potentially problematic data
      valid_attrs = %{
        lsn: 200,
        table: "accounts",
        op: :insert,
        data: %{"id" => account.id, "name" => "valid"},
        old_data: nil,
        vsn: 0
      }

      # This might cause issues depending on your validation
      potentially_invalid_attrs = %{
        lsn: 201,
        table: "accounts",
        op: :insert,
        data: %{"bad" => "data"},
        old_data: nil,
        vsn: 0
      }

      state = %{flush_buffer: [potentially_invalid_attrs, valid_attrs], last_flushed_lsn: 0}

      result_state = on_flush(state)

      # Buffer should always be cleared, even on partial failure
      assert result_state.flush_buffer == []
    end

    test "handles Postgrex.Error exceptions" do
      # Create data that will definitely cause a database error
      bad_attrs = %{
        lsn: 300,
        table: "accounts",
        op: :insert,
        # Missing account id
        data: %{"test" => "fail"},
        old_data: nil,
        vsn: 0
      }

      state = %{flush_buffer: [bad_attrs], last_flushed_lsn: 0}

      result_state = on_flush(state)

      # Even on exception, buffer should be cleared
      assert result_state.flush_buffer == []
    end

    test "calculates last_flushed_lsn correctly for partial success", %{account: account} do
      # Create multiple records where some might fail
      attrs_list = [
        %{
          lsn: 400,
          table: "accounts",
          op: :insert,
          data: %{"id" => account.id, "account_id" => account.id},
          old_data: nil,
          vsn: 0
        },
        %{
          lsn: 401,
          table: "accounts",
          op: :insert,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0
        },
        %{
          lsn: 402,
          table: "accounts",
          op: :insert,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0
        }
      ]

      state = %{flush_buffer: attrs_list, last_flushed_lsn: 399}

      result_state = on_flush(state)

      # Should update last_flushed_lsn appropriately
      assert result_state.last_flushed_lsn >= 400
      assert result_state.flush_buffer == []
    end
  end

  describe "LSN tracking and ordering" do
    test "LSNs are preserved correctly in buffer" do
      lsns = [1000, 1001, 1002]

      state = %{flush_buffer: []}

      # Add multiple operations with specific LSNs
      final_state =
        Enum.reduce(lsns, state, fn lsn, acc_state ->
          on_insert(
            lsn,
            "accounts",
            %{"id" => Ecto.UUID.generate(), "name" => "test_#{lsn}"},
            acc_state
          )
        end)

      # Verify LSNs are preserved in buffer (in reverse order since we prepend)
      buffer_lsns = Enum.map(final_state.flush_buffer, & &1.lsn)
      assert buffer_lsns == Enum.reverse(lsns)

      # Verify each entry has correct LSN
      Enum.zip(final_state.flush_buffer, Enum.reverse(lsns))
      |> Enum.each(fn {attrs, expected_lsn} ->
        assert attrs.lsn == expected_lsn
      end)
    end

    test "handles large LSN values", %{account: account} do
      large_lsn = 999_999_999_999_999

      state = %{flush_buffer: []}
      result_state = on_insert(large_lsn, "accounts", %{"id" => account.id}, state)

      [attrs] = result_state.flush_buffer
      assert attrs.lsn == large_lsn
    end

    test "preserves LSN ordering through flush", %{account: account} do
      # Add operations with non-sequential LSNs
      lsns = [1005, 1003, 1007, 1001]

      state = %{flush_buffer: [], last_flushed_lsn: 0}

      final_state =
        Enum.reduce(lsns, state, fn lsn, acc_state ->
          on_insert(
            lsn,
            "accounts",
            %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
            acc_state
          )
        end)

      # Flush to database
      on_flush(final_state)

      # Verify records in database have correct LSNs
      change_logs = Repo.all(from cl in ChangeLog, where: cl.lsn in ^lsns, order_by: cl.lsn)
      db_lsns = Enum.map(change_logs, & &1.lsn)
      assert db_lsns == Enum.sort(lsns)
    end
  end

  describe "versioning" do
    test "all operations use correct version number", %{account: account} do
      state = %{flush_buffer: []}

      # Test insert
      state1 = on_insert(100, "accounts", %{"id" => account.id}, state)
      assert hd(state1.flush_buffer).vsn == 0

      # Test update
      state2 =
        on_update(
          101,
          "accounts",
          %{"id" => account.id},
          %{"id" => account.id, "updated" => true},
          state1
        )

      assert hd(state2.flush_buffer).vsn == 0

      # Test delete
      state3 = on_delete(102, "accounts", %{"id" => account.id}, state2)
      assert hd(state3.flush_buffer).vsn == 0
    end
  end

  describe "edge cases and error scenarios" do
    test "handles nil data gracefully" do
      state = %{flush_buffer: [], last_flushed_lsn: 0}

      result_state = on_insert(500, "accounts", nil, state)

      [attrs] = result_state.flush_buffer
      assert attrs.data == nil
      assert attrs.lsn == 500
    end

    test "handles empty data maps" do
      state = %{flush_buffer: []}

      result_state = on_insert(501, "accounts", %{}, state)

      [attrs] = result_state.flush_buffer
      assert attrs.data == %{}
      assert attrs.lsn == 501
    end

    test "handles very large buffers" do
      state = %{flush_buffer: [], last_flushed_lsn: 0}

      # Simulate adding many operations
      operations = 1..100

      final_state =
        Enum.reduce(operations, state, fn i, acc_state ->
          on_insert(
            i,
            "accounts",
            %{"id" => Ecto.UUID.generate(), "name" => "user#{i}"},
            acc_state
          )
        end)

      assert length(final_state.flush_buffer) == 100

      # Verify all LSNs are present
      buffer_lsns = Enum.map(final_state.flush_buffer, & &1.lsn) |> Enum.sort()
      assert buffer_lsns == Enum.to_list(1..100)
    end
  end

  describe "full integration scenarios" do
    test "complete workflow from operations to database", %{account: account} do
      # Start with empty state
      state = %{flush_buffer: [], last_flushed_lsn: 0}

      # Add several operations
      state1 =
        on_insert(
          600,
          "accounts",
          %{"id" => account.id, "name" => "user1", "account_id" => account.id},
          state
        )

      state2 =
        on_update(
          601,
          "accounts",
          %{"id" => account.id, "name" => "user1", "account_id" => account.id},
          %{"id" => account.id, "name" => "user1_updated", "account_id" => account.id},
          state1
        )

      user2_id = Ecto.UUID.generate()

      state3 =
        on_insert(
          602,
          "accounts",
          %{"id" => user2_id, "name" => "user2", "account_id" => account.id},
          state2
        )

      state4 =
        on_delete(
          603,
          "accounts",
          %{"id" => user2_id, "name" => "user2", "account_id" => account.id},
          state3
        )

      # Verify buffer has 4 items
      assert length(state4.flush_buffer) == 4

      # Flush and verify
      final_state = on_flush(state4)
      assert final_state.flush_buffer == []
      assert final_state.last_flushed_lsn == 603

      # Verify all records were created in database
      change_logs =
        Repo.all(from cl in ChangeLog, where: cl.lsn in [600, 601, 602, 603], order_by: cl.lsn)

      assert length(change_logs) == 4

      [insert1, update1, insert2, delete2] = change_logs
      assert insert1.op == :insert
      assert insert1.lsn == 600
      assert update1.op == :update
      assert update1.lsn == 601
      assert insert2.op == :insert
      assert insert2.lsn == 602
      assert delete2.op == :delete
      assert delete2.lsn == 603
    end
  end
end
