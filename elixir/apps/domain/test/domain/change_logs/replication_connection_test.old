defmodule Domain.ChangeLogs.ReplicationConnectionTest do
  use Domain.DataCase, async: true

  import Ecto.Query
  alias Domain.ChangeLogs.ReplicationConnection
  alias Domain.ChangeLog
  alias Domain.Repo

  setup do
    account = Fixtures.Accounts.create_account()
    %{account: account}
  end

  describe "on_write/6 for inserts" do
    test "handles account inserts", %{account: account} do
      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12345,
          :insert,
          "accounts",
          nil,
          %{"id" => account.id, "name" => "test account"}
        )

      assert result_state == %{
               flush_buffer: %{
                 12345 => %{
                   data: %{
                     "id" => account.id,
                     "name" => "test account"
                   },
                   table: "accounts",
                   vsn: 0,
                   op: :insert,
                   account_id: account.id,
                   lsn: 12345,
                   old_data: nil
                 }
               }
             }
    end

    test "adds insert operation to flush buffer for non-account tables", %{account: account} do
      table = "resources"

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "name" => "test resource"
      }

      lsn = 12345

      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          lsn,
          :insert,
          table,
          nil,
          data
        )

      assert map_size(result_state.flush_buffer) == 1
      assert Map.has_key?(result_state.flush_buffer, lsn)

      attrs = result_state.flush_buffer[lsn]
      assert attrs.lsn == lsn
      assert attrs.table == table
      assert attrs.op == :insert
      assert attrs.data == data
      assert attrs.old_data == nil
      assert attrs.account_id == account.id
      assert attrs.vsn == 0
    end

    test "preserves existing buffer items", %{account: account} do
      existing_lsn = 100

      existing_item = %{
        lsn: existing_lsn,
        table: "other_table",
        op: :update,
        account_id: account.id,
        data: %{"id" => "existing"},
        old_data: nil,
        vsn: 0
      }

      initial_state = %{flush_buffer: %{existing_lsn => existing_item}}

      new_lsn = 101

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          new_lsn,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert map_size(result_state.flush_buffer) == 2
      assert result_state.flush_buffer[existing_lsn] == existing_item
      assert Map.has_key?(result_state.flush_buffer, new_lsn)
    end

    test "ignores relay_group tokens" do
      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12345,
          :insert,
          "tokens",
          nil,
          %{"id" => Ecto.UUID.generate(), "type" => "relay_group"}
        )

      assert result_state == initial_state
    end

    test "handles complex data structures", %{account: account} do
      complex_data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "nested" => %{"key" => "value", "array" => [1, 2, 3]},
        "null_field" => nil,
        "boolean" => true
      }

      state = %{flush_buffer: %{}}
      lsn = 200

      result_state =
        ReplicationConnection.on_write(
          state,
          lsn,
          :insert,
          "resources",
          nil,
          complex_data
        )

      attrs = result_state.flush_buffer[lsn]
      assert attrs.data == complex_data
    end
  end

  describe "on_write/6 for updates" do
    test "adds update operation to flush buffer", %{account: account} do
      table = "resources"
      old_data = %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "old name"}
      data = %{"id" => old_data["id"], "account_id" => account.id, "name" => "new name"}
      lsn = 12346

      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          lsn,
          :update,
          table,
          old_data,
          data
        )

      assert map_size(result_state.flush_buffer) == 1
      attrs = result_state.flush_buffer[lsn]

      assert attrs.lsn == lsn
      assert attrs.table == table
      assert attrs.op == :update
      assert attrs.data == data
      assert attrs.old_data == old_data
      assert attrs.account_id == account.id
      assert attrs.vsn == 0
    end

    test "handles account updates specially", %{account: account} do
      old_data = %{"id" => account.id, "name" => "old name"}
      data = %{"id" => account.id, "name" => "new name"}
      lsn = 12346

      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          lsn,
          :update,
          "accounts",
          old_data,
          data
        )

      # Account updates should be buffered
      assert map_size(result_state.flush_buffer) == 1
      attrs = result_state.flush_buffer[lsn]
      assert attrs.table == "accounts"
      assert attrs.op == :update
      assert attrs.account_id == account.id
    end

    test "handles complex data changes", %{account: account} do
      old_data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "settings" => %{"theme" => "dark"},
        "tags" => ["old"]
      }

      new_data = %{
        "id" => old_data["id"],
        "account_id" => account.id,
        "settings" => %{"theme" => "light", "language" => "en"},
        "tags" => ["new", "updated"]
      }

      state = %{flush_buffer: %{}}
      lsn = 300

      result_state =
        ReplicationConnection.on_write(
          state,
          lsn,
          :update,
          "resources",
          old_data,
          new_data
        )

      attrs = result_state.flush_buffer[lsn]
      assert attrs.old_data == old_data
      assert attrs.data == new_data
    end
  end

  describe "on_write/6 for deletes" do
    test "handles account deletes", %{account: account} do
      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12345,
          :delete,
          "accounts",
          %{"id" => account.id, "name" => "deleted account"},
          nil
        )

      assert result_state == %{
               flush_buffer: %{
                 12345 => %{
                   data: nil,
                   table: "accounts",
                   vsn: 0,
                   op: :delete,
                   account_id: account.id,
                   lsn: 12345,
                   old_data: %{"id" => account.id, "name" => "deleted account"}
                 }
               }
             }
    end

    test "adds delete operation to flush buffer for deleted records", %{account: account} do
      table = "resources"

      old_data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "name" => "deleted resource"
      }

      lsn = 12347

      initial_state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          lsn,
          :delete,
          table,
          old_data,
          nil
        )

      assert map_size(result_state.flush_buffer) == 1
      attrs = result_state.flush_buffer[lsn]

      assert attrs.lsn == lsn
      assert attrs.table == table
      assert attrs.op == :delete
      assert attrs.data == nil
      assert attrs.old_data == old_data
      assert attrs.account_id == account.id
      assert attrs.vsn == 0
    end
  end

  describe "multiple operations and buffer accumulation" do
    test "operations accumulate in flush buffer correctly", %{account: account} do
      initial_state = %{flush_buffer: %{}}

      # Insert
      state1 =
        ReplicationConnection.on_write(
          initial_state,
          100,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test"}
        )

      assert map_size(state1.flush_buffer) == 1

      # Update
      resource_id = Ecto.UUID.generate()

      state2 =
        ReplicationConnection.on_write(
          state1,
          101,
          :update,
          "resources",
          %{"id" => resource_id, "account_id" => account.id, "name" => "test"},
          %{"id" => resource_id, "account_id" => account.id, "name" => "updated"}
        )

      assert map_size(state2.flush_buffer) == 2

      # Delete (non-soft)
      state3 =
        ReplicationConnection.on_write(
          state2,
          102,
          :delete,
          "resources",
          %{"id" => resource_id, "account_id" => account.id, "name" => "updated"},
          nil
        )

      assert map_size(state3.flush_buffer) == 3

      # Verify LSNs
      assert Map.has_key?(state3.flush_buffer, 100)
      assert Map.has_key?(state3.flush_buffer, 101)
      assert Map.has_key?(state3.flush_buffer, 102)

      assert state3.flush_buffer[100].op == :insert
      assert state3.flush_buffer[101].op == :update
      assert state3.flush_buffer[102].op == :delete
    end
  end

  describe "on_flush/1" do
    test "handles empty flush buffer" do
      state = %{flush_buffer: %{}}

      result_state = ReplicationConnection.on_flush(state)

      assert result_state == state
    end

    test "successfully flushes buffer and clears it", %{account: account} do
      # Create valid change log data
      attrs1 = %{
        lsn: 100,
        table: "resources",
        op: :insert,
        account_id: account.id,
        data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test1"},
        old_data: nil,
        vsn: 0
      }

      attrs2 = %{
        lsn: 101,
        table: "resources",
        op: :update,
        account_id: account.id,
        data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test2"},
        old_data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test1"},
        vsn: 0
      }

      state = %{
        flush_buffer: %{100 => attrs1, 101 => attrs2},
        last_flushed_lsn: 99
      }

      result_state = ReplicationConnection.on_flush(state)

      assert result_state.flush_buffer == %{}
      # Should be the highest LSN
      assert result_state.last_flushed_lsn == 101

      # Verify actual records were created in database
      change_logs = Repo.all(from cl in ChangeLog, where: cl.lsn in [100, 101], order_by: cl.lsn)
      assert length(change_logs) == 2

      [log1, log2] = change_logs
      assert log1.lsn == 100
      assert log1.op == :insert
      assert log2.lsn == 101
      assert log2.op == :update
    end

    test "calculates last_flushed_lsn correctly as max LSN", %{account: account} do
      # Create multiple records with non-sequential LSNs
      attrs_map = %{
        400 => %{
          lsn: 400,
          table: "resources",
          op: :insert,
          account_id: account.id,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0
        },
        402 => %{
          lsn: 402,
          table: "resources",
          op: :insert,
          account_id: account.id,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0
        },
        401 => %{
          lsn: 401,
          table: "resources",
          op: :insert,
          account_id: account.id,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0
        }
      }

      state = %{flush_buffer: attrs_map, last_flushed_lsn: 399}

      result_state = ReplicationConnection.on_flush(state)

      # Should update to max LSN (402)
      assert result_state.last_flushed_lsn == 402
      assert result_state.flush_buffer == %{}
    end
  end

  describe "LSN tracking and ordering" do
    test "LSNs are preserved correctly in buffer" do
      lsns = [1000, 1001, 1002]

      state = %{flush_buffer: %{}}

      # Add multiple operations with specific LSNs
      final_state =
        Enum.reduce(lsns, state, fn lsn, acc_state ->
          ReplicationConnection.on_write(
            acc_state,
            lsn,
            :insert,
            "resources",
            nil,
            %{
              "id" => Ecto.UUID.generate(),
              "account_id" => "test-account",
              "name" => "test_#{lsn}"
            }
          )
        end)

      # Verify LSNs are preserved as keys
      assert Map.keys(final_state.flush_buffer) |> Enum.sort() == lsns

      # Verify each entry has correct LSN
      Enum.each(lsns, fn lsn ->
        assert final_state.flush_buffer[lsn].lsn == lsn
      end)
    end

    test "handles large LSN values", %{account: account} do
      large_lsn = 999_999_999_999_999

      state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_write(
          state,
          large_lsn,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      attrs = result_state.flush_buffer[large_lsn]
      assert attrs.lsn == large_lsn
    end

    test "preserves LSN ordering through flush", %{account: account} do
      # Add operations with non-sequential LSNs
      lsns = [1005, 1003, 1007, 1001]

      state = %{flush_buffer: %{}, last_flushed_lsn: 0}

      final_state =
        Enum.reduce(lsns, state, fn lsn, acc_state ->
          ReplicationConnection.on_write(
            acc_state,
            lsn,
            :insert,
            "resources",
            nil,
            %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
          )
        end)

      # Flush to database
      ReplicationConnection.on_flush(final_state)

      # Verify records in database have correct LSNs
      change_logs = Repo.all(from cl in ChangeLog, where: cl.lsn in ^lsns, order_by: cl.lsn)
      db_lsns = Enum.map(change_logs, & &1.lsn)
      assert db_lsns == Enum.sort(lsns)
    end
  end

  describe "edge cases and error scenarios" do
    test "logs error for writes without account_id" do
      import ExUnit.CaptureLog

      state = %{flush_buffer: %{}}

      log =
        capture_log(fn ->
          result =
            ReplicationConnection.on_write(
              state,
              500,
              :insert,
              "some_table",
              nil,
              %{"id" => Ecto.UUID.generate(), "name" => "no account_id"}
            )

          # State should remain unchanged
          assert result == state
        end)

      assert log =~ "Unexpected write operation!"
      assert log =~ "lsn=500"
    end

    test "handles account_id in old_data for deletes", %{account: account} do
      state = %{flush_buffer: %{}}
      lsn = 600

      result_state =
        ReplicationConnection.on_write(
          state,
          lsn,
          :delete,
          "resources",
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          nil
        )

      assert map_size(result_state.flush_buffer) == 1
      assert result_state.flush_buffer[lsn].account_id == account.id
    end

    test "handles very large buffers" do
      account_id = Ecto.UUID.generate()
      state = %{flush_buffer: %{}, last_flushed_lsn: 0}

      # Simulate adding many operations
      operations = 1..100

      final_state =
        Enum.reduce(operations, state, fn i, acc_state ->
          ReplicationConnection.on_write(
            acc_state,
            i,
            :insert,
            "resources",
            nil,
            %{"id" => Ecto.UUID.generate(), "account_id" => account_id, "name" => "user#{i}"}
          )
        end)

      assert map_size(final_state.flush_buffer) == 100

      # Verify all LSNs are present
      buffer_lsns = Map.keys(final_state.flush_buffer) |> Enum.sort()
      assert buffer_lsns == Enum.to_list(1..100)
    end
  end

  describe "special table handling" do
    test "ignores relay_group token updates" do
      state = %{flush_buffer: %{}}

      # Update where old_data has relay_group type
      result_state1 =
        ReplicationConnection.on_write(
          state,
          100,
          :update,
          "tokens",
          %{"id" => Ecto.UUID.generate(), "type" => "relay_group"},
          %{"id" => Ecto.UUID.generate(), "type" => "relay_group", "updated" => true}
        )

      assert result_state1 == state

      # Update where new data has relay_group type
      result_state2 =
        ReplicationConnection.on_write(
          state,
          101,
          :update,
          "tokens",
          %{"id" => Ecto.UUID.generate(), "type" => "other"},
          %{"id" => Ecto.UUID.generate(), "type" => "relay_group"}
        )

      assert result_state2 == state
    end

    test "processes non-relay_group tokens normally", %{account: account} do
      state = %{flush_buffer: %{}}
      lsn = 102

      result_state =
        ReplicationConnection.on_write(
          state,
          lsn,
          :insert,
          "tokens",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "type" => "browser"}
        )

      assert map_size(result_state.flush_buffer) == 1
      assert result_state.flush_buffer[lsn].table == "tokens"
    end
  end
end
