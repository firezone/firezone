defmodule Portal.ChangeLogs.ReplicationConnectionTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  alias Portal.ChangeLogs.ReplicationConnection
  alias Portal.ChangeLog

  @commit_timestamp ~U[2026-05-26 12:00:00.123456Z]

  setup do
    tables =
      Application.fetch_env!(:portal, Portal.ChangeLogs.ReplicationConnection)
      |> Keyword.fetch!(:table_subscriptions)

    account = account_fixture()

    # In production every Write is preceded by a Begin that populates
    # current_commit_timestamp, so set it up here for on_write/6 tests.
    initial_state = %{flush_buffer: %{}, current_commit_timestamp: @commit_timestamp}

    %{account: account, tables: tables, initial_state: initial_state}
  end

  describe "configured tables" do
    test "includes client and gateway sessions in the audit publication", %{tables: tables} do
      assert "client_sessions" in tables
      assert "gateway_sessions" in tables
    end
  end

  describe "on_begin/2" do
    test "captures commit_timestamp on the transaction state" do
      commit_timestamp = ~U[2026-05-26 12:00:00.123456Z]
      state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_begin(state, %{commit_timestamp: commit_timestamp})

      assert result_state.current_commit_timestamp == commit_timestamp
    end

    test "clears the previous transaction's subject" do
      state = %{flush_buffer: %{}, current_subject: "stale"}

      result_state =
        ReplicationConnection.on_begin(state, %{
          commit_timestamp: ~U[2026-05-26 12:00:00Z]
        })

      refute Map.has_key?(result_state, :current_subject)
    end

    test "overwrites a stale commit_timestamp from a prior transaction" do
      state = %{
        flush_buffer: %{},
        current_commit_timestamp: ~U[2026-05-26 11:00:00Z]
      }

      result_state =
        ReplicationConnection.on_begin(state, %{
          commit_timestamp: ~U[2026-05-26 12:00:00Z]
        })

      assert result_state.current_commit_timestamp == ~U[2026-05-26 12:00:00Z]
    end
  end

  describe "on_write/6 for inserts" do
    test "handles account inserts", %{account: account, initial_state: initial_state} do
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
                   old_data: nil,
                   subject: nil,
                   committed_at: @commit_timestamp
                 }
               },
               current_commit_timestamp: @commit_timestamp
             }
    end

    test "adds insert operation to flush buffer for non-account tables", %{
      account: account,
      initial_state: initial_state
    } do
      table = "resources"

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "name" => "test resource"
      }

      lsn = 12345

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

    test "preserves existing buffer items", %{account: account, initial_state: initial_state} do
      existing_lsn = 100

      existing_item = %{
        lsn: existing_lsn,
        table: "other_table",
        op: :update,
        account_id: account.id,
        data: %{"id" => "existing"},
        old_data: nil,
        vsn: 0,
        subject: nil,
        committed_at: @commit_timestamp
      }

      initial_state = %{initial_state | flush_buffer: %{existing_lsn => existing_item}}

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

    test "ignores relay token inserts", %{initial_state: initial_state} do
      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12345,
          :insert,
          "tokens",
          nil,
          %{"id" => Ecto.UUID.generate(), "type" => "relay"}
        )

      assert result_state == initial_state
    end

    test "handles complex data structures", %{account: account, initial_state: initial_state} do
      complex_data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "nested" => %{"key" => "value", "array" => [1, 2, 3]},
        "null_field" => nil,
        "boolean" => true
      }

      lsn = 200

      result_state =
        ReplicationConnection.on_write(
          initial_state,
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
    test "adds update operation to flush buffer", %{
      account: account,
      initial_state: initial_state
    } do
      table = "resources"
      old_data = %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "old name"}
      data = %{"id" => old_data["id"], "account_id" => account.id, "name" => "new name"}
      lsn = 12346

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

    test "handles account updates specially", %{
      account: account,
      initial_state: initial_state
    } do
      old_data = %{"id" => account.id, "name" => "old name"}
      data = %{"id" => account.id, "name" => "new name"}
      lsn = 12346

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          lsn,
          :update,
          "accounts",
          old_data,
          data
        )

      assert map_size(result_state.flush_buffer) == 1
      attrs = result_state.flush_buffer[lsn]
      assert attrs.table == "accounts"
      assert attrs.op == :update
      assert attrs.account_id == account.id
    end
  end

  describe "on_write/6 for deletes" do
    test "handles account deletes", %{account: account, initial_state: initial_state} do
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
                   old_data: %{"id" => account.id, "name" => "deleted account"},
                   subject: nil,
                   committed_at: @commit_timestamp
                 }
               },
               current_commit_timestamp: @commit_timestamp
             }
    end

    test "adds delete operation to flush buffer", %{
      account: account,
      initial_state: initial_state
    } do
      table = "resources"

      old_data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "name" => "deleted resource"
      }

      lsn = 12347

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
    test "operations accumulate in flush buffer correctly", %{
      account: account,
      initial_state: initial_state
    } do
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
      assert state3.flush_buffer[100].op == :insert
      assert state3.flush_buffer[101].op == :update
      assert state3.flush_buffer[102].op == :delete
    end
  end

  describe "committed_at propagation" do
    test "buffered entry inherits commit_timestamp from current transaction", %{
      account: account
    } do
      commit_timestamp = ~U[2026-05-26 12:00:00.654321Z]

      state =
        ReplicationConnection.on_begin(%{flush_buffer: %{}}, %{
          commit_timestamp: commit_timestamp
        })

      result_state =
        ReplicationConnection.on_write(
          state,
          12345,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert result_state.flush_buffer[12345].committed_at == commit_timestamp
    end

    test "every row in a transaction shares the same commit_timestamp", %{account: account} do
      commit_timestamp = ~U[2026-05-26 12:00:00.000001Z]

      state =
        ReplicationConnection.on_begin(%{flush_buffer: %{}}, %{
          commit_timestamp: commit_timestamp
        })

      state =
        ReplicationConnection.on_write(
          state,
          200,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      state =
        ReplicationConnection.on_write(
          state,
          201,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert state.flush_buffer[200].committed_at == commit_timestamp
      assert state.flush_buffer[201].committed_at == commit_timestamp
    end

    test "persists committed_at end-to-end through on_flush", %{account: account} do
      commit_timestamp = ~U[2026-05-26 12:00:00.999999Z]

      state =
        %{flush_buffer: %{}, last_flushed_lsn: 0}
        |> ReplicationConnection.on_begin(%{commit_timestamp: commit_timestamp})
        |> ReplicationConnection.on_write(
          500,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test"}
        )
        |> ReplicationConnection.on_flush()

      assert state.flush_buffer == %{}

      change_log = Repo.one(from cl in ChangeLog, where: cl.lsn == 500)
      assert change_log.committed_at == commit_timestamp
    end
  end

  describe "on_flush/1" do
    test "handles empty flush buffer" do
      state = %{flush_buffer: %{}}
      result_state = ReplicationConnection.on_flush(state)
      assert result_state == state
    end

    test "successfully flushes buffer and clears it", %{account: account} do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]

      attrs1 = %{
        lsn: 100,
        table: "resources",
        op: :insert,
        account_id: account.id,
        data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test1"},
        old_data: nil,
        vsn: 0,
        subject: nil,
        committed_at: committed_at
      }

      attrs2 = %{
        lsn: 101,
        table: "resources",
        op: :update,
        account_id: account.id,
        data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test2"},
        old_data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test1"},
        vsn: 0,
        subject: nil,
        committed_at: committed_at
      }

      state = %{
        flush_buffer: %{100 => attrs1, 101 => attrs2},
        last_flushed_lsn: 99
      }

      result_state = ReplicationConnection.on_flush(state)

      assert result_state.flush_buffer == %{}
      assert result_state.last_flushed_lsn == 101

      change_logs = Repo.all(from cl in ChangeLog, where: cl.lsn in [100, 101], order_by: cl.lsn)
      assert length(change_logs) == 2

      [log1, log2] = change_logs
      assert log1.lsn == 100
      assert log1.op == :insert
      assert log1.committed_at == committed_at
      assert log2.lsn == 101
      assert log2.op == :update
      assert log2.committed_at == committed_at
    end

    test "calculates last_flushed_lsn correctly as max LSN", %{account: account} do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]

      attrs_map = %{
        400 => %{
          lsn: 400,
          table: "resources",
          op: :insert,
          account_id: account.id,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0,
          subject: nil,
          committed_at: committed_at
        },
        402 => %{
          lsn: 402,
          table: "resources",
          op: :insert,
          account_id: account.id,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0,
          subject: nil,
          committed_at: committed_at
        },
        401 => %{
          lsn: 401,
          table: "resources",
          op: :insert,
          account_id: account.id,
          data: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          old_data: nil,
          vsn: 0,
          subject: nil,
          committed_at: committed_at
        }
      }

      state = %{flush_buffer: attrs_map, last_flushed_lsn: 399}
      result_state = ReplicationConnection.on_flush(state)

      assert result_state.last_flushed_lsn == 402
      assert result_state.flush_buffer == %{}
    end
  end

  describe "edge cases" do
    test "logs error for writes without account_id", %{initial_state: initial_state} do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          result =
            ReplicationConnection.on_write(
              initial_state,
              500,
              :insert,
              "some_table",
              nil,
              %{"id" => Ecto.UUID.generate(), "name" => "no account_id"}
            )

          assert result == initial_state
        end)

      assert log =~ "Unexpected write operation!"
      assert log =~ "lsn=500"
    end

    test "ignores relay token updates", %{initial_state: initial_state} do
      result_state1 =
        ReplicationConnection.on_write(
          initial_state,
          100,
          :update,
          "tokens",
          %{"id" => Ecto.UUID.generate(), "type" => "relay"},
          %{"id" => Ecto.UUID.generate(), "type" => "relay", "updated" => true}
        )

      assert result_state1 == initial_state

      result_state2 =
        ReplicationConnection.on_write(
          initial_state,
          101,
          :update,
          "tokens",
          %{"id" => Ecto.UUID.generate(), "type" => "other"},
          %{"id" => Ecto.UUID.generate(), "type" => "relay"}
        )

      assert result_state2 == initial_state
    end

    test "processes non-relay tokens normally", %{
      account: account,
      initial_state: initial_state
    } do
      lsn = 102

      result_state =
        ReplicationConnection.on_write(
          initial_state,
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
