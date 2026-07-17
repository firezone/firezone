defmodule Portal.ChangeLogs.ConsumerTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  alias Portal.ChangeLogs.Consumer
  alias Portal.ChangeLogs.Consumer.Database
  alias Portal.ChangeLog
  alias Portal.Types.LogId

  @commit_timestamp ~U[2026-05-26 12:00:00.123000Z]
  @seq_start 1_700_000_000_000_000

  setup do
    tables =
      Application.fetch_env!(:portal, Portal.ChangeLogs.Consumer)
      |> Keyword.fetch!(:table_subscriptions)

    account = account_fixture()

    # In production every Write is preceded by a Begin that populates
    # commit_timestamp, seq_start, and tenant_offsets, so seed them here
    # for on_write/6 tests.
    initial_state = %{
      flush_buffer: %{},
      commit_timestamp: @commit_timestamp,
      seq_start: @seq_start,
      tenant_offsets: %{}
    }

    %{account: account, tables: tables, initial_state: initial_state}
  end

  describe "configured tables" do
    test "excludes session tables, which belong to the session_logs publication", %{
      tables: tables
    } do
      refute "client_sessions" in tables
      refute "gateway_sessions" in tables
      refute "portal_sessions" in tables
    end

    test "includes trust anchors in the audit publication", %{tables: tables} do
      assert "trust_anchors" in tables
      assert "trust_anchor_certificates" in tables
    end

    test "includes the provider log sink tables but not the delivery machinery", %{
      tables: tables
    } do
      for table <- ~w[splunk_log_sinks datadog_log_sinks newrelic_log_sinks elastic_log_sinks
                      sentinel_log_sinks s3_log_sinks] do
        assert table in tables
      end

      refute "log_sinks" in tables
      refute "log_sink_cursors" in tables
    end
  end

  describe "on_begin/2" do
    test "captures commit_timestamp on the transaction state" do
      commit_timestamp = ~U[2026-05-26 12:00:00.123000Z]
      state = %{flush_buffer: %{}}

      result_state =
        Consumer.on_begin(state, %{commit_timestamp: commit_timestamp})

      assert result_state.commit_timestamp == commit_timestamp
    end

    test "clears the previous transaction's subject" do
      state = %{flush_buffer: %{}, current_subject: "stale"}

      result_state =
        Consumer.on_begin(state, %{
          commit_timestamp: ~U[2026-05-26 12:00:00Z]
        })

      refute Map.has_key?(result_state, :current_subject)
    end

    test "overwrites a stale commit_timestamp from a prior transaction" do
      state = %{
        flush_buffer: %{},
        commit_timestamp: ~U[2026-05-26 11:00:00Z]
      }

      result_state =
        Consumer.on_begin(state, %{
          commit_timestamp: ~U[2026-05-26 12:00:00Z]
        })

      assert result_state.commit_timestamp == ~U[2026-05-26 12:00:00Z]
    end

    test "seeds seq_start and tenant_offsets on first call" do
      before = Database.fetch_seq_start()
      state = %{flush_buffer: %{}}

      result_state =
        Consumer.on_begin(state, %{
          commit_timestamp: ~U[2026-05-26 12:00:00Z]
        })

      assert is_integer(result_state.seq_start)
      assert result_state.seq_start >= before
      assert result_state.tenant_offsets == %{}
    end

    test "preserves seq_start and tenant_offsets on subsequent calls" do
      state = %{flush_buffer: %{}, seq_start: @seq_start, tenant_offsets: %{"x" => 7}}

      result_state =
        Consumer.on_begin(state, %{
          commit_timestamp: ~U[2026-05-26 12:00:00Z]
        })

      assert result_state.seq_start == @seq_start
      assert result_state.tenant_offsets == %{"x" => 7}
    end
  end

  describe "on_write/6 for inserts" do
    test "handles account inserts", %{account: account, initial_state: initial_state} do
      result_state =
        Consumer.on_write(
          initial_state,
          12345,
          :insert,
          "accounts",
          nil,
          %{"id" => account.id, "name" => "test account"}
        )

      assert map_size(result_state.flush_buffer) == 1
      assert result_state.commit_timestamp == @commit_timestamp

      attrs = result_state.flush_buffer[12345]
      assert attrs.lsn == 12345
      assert attrs.object == "accounts"
      assert attrs.operation == :insert
      assert attrs.account_id == account.id
      assert attrs.after == %{"id" => account.id, "name" => "test account"}
      assert attrs.before == nil
      assert attrs.subject == nil
      assert attrs.vsn == 0
      assert attrs.timestamp == @commit_timestamp
      assert attrs.log_id == LogId.build_change_log(@seq_start, 0)
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
        Consumer.on_write(
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
      assert attrs.object == table
      assert attrs.operation == :insert
      assert attrs.after == data
      assert attrs.before == nil
      assert attrs.account_id == account.id
      assert attrs.vsn == 0
      assert attrs.timestamp == @commit_timestamp
    end

    test "redacts log sink credentials in the buffered snapshot", %{
      account: account,
      initial_state: initial_state
    } do
      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "name" => "SOC Splunk",
        "collector_url" => "https://http-inputs-acme.splunkcloud.com",
        "hec_token" => "super-secret-token"
      }

      result_state =
        Consumer.on_write(
          initial_state,
          12345,
          :insert,
          "splunk_log_sinks",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12345]
      assert attrs.after["hec_token"] == "[redacted]"
      assert attrs.after["collector_url"] == "https://http-inputs-acme.splunkcloud.com"
    end

    test "preserves existing buffer items", %{account: account, initial_state: initial_state} do
      existing_lsn = 100

      existing_item = %{
        log_id: LogId.build_change_log(@seq_start, 99),
        timestamp: @commit_timestamp,
        lsn: existing_lsn,
        object: "other_table",
        operation: :update,
        account_id: account.id,
        after: %{"id" => "existing"},
        before: nil,
        vsn: 0,
        subject: nil
      }

      initial_state = %{initial_state | flush_buffer: %{existing_lsn => existing_item}}

      new_lsn = 101

      result_state =
        Consumer.on_write(
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
        Consumer.on_write(
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
        Consumer.on_write(
          initial_state,
          lsn,
          :insert,
          "resources",
          nil,
          complex_data
        )

      attrs = result_state.flush_buffer[lsn]
      assert attrs.after == complex_data
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
        Consumer.on_write(
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
      assert attrs.object == table
      assert attrs.operation == :update
      assert attrs.after == data
      assert attrs.before == old_data
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
        Consumer.on_write(
          initial_state,
          lsn,
          :update,
          "accounts",
          old_data,
          data
        )

      assert map_size(result_state.flush_buffer) == 1
      attrs = result_state.flush_buffer[lsn]
      assert attrs.object == "accounts"
      assert attrs.operation == :update
      assert attrs.account_id == account.id
    end

    test "preserves trust anchor certificate PEM and fingerprint text", %{
      account: account,
      initial_state: initial_state
    } do
      old_data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "trust_anchor_id" => Ecto.UUID.generate(),
        "pem" => "old PEM text",
        "fingerprint" => "old fingerprint"
      }

      data = %{
        "id" => old_data["id"],
        "account_id" => account.id,
        "trust_anchor_id" => old_data["trust_anchor_id"],
        "pem" => "new PEM text",
        "fingerprint" => "new fingerprint"
      }

      lsn = 12347

      result_state =
        Consumer.on_write(
          initial_state,
          lsn,
          :update,
          "trust_anchor_certificates",
          old_data,
          data
        )

      attrs = result_state.flush_buffer[lsn]

      assert attrs.object == "trust_anchor_certificates"
      assert attrs.before["pem"] == "old PEM text"
      assert attrs.after["pem"] == "new PEM text"
      assert attrs.before["fingerprint"] == "old fingerprint"
      assert attrs.after["fingerprint"] == "new fingerprint"
    end
  end

  describe "on_write/6 for deletes" do
    test "handles account deletes", %{account: account, initial_state: initial_state} do
      result_state =
        Consumer.on_write(
          initial_state,
          12345,
          :delete,
          "accounts",
          %{"id" => account.id, "name" => "deleted account"},
          nil
        )

      assert map_size(result_state.flush_buffer) == 1
      assert result_state.commit_timestamp == @commit_timestamp

      attrs = result_state.flush_buffer[12345]
      assert attrs.lsn == 12345
      assert attrs.object == "accounts"
      assert attrs.operation == :delete
      assert attrs.account_id == account.id
      assert attrs.after == nil
      assert attrs.before == %{"id" => account.id, "name" => "deleted account"}
      assert attrs.subject == nil
      assert attrs.vsn == 0
      assert attrs.timestamp == @commit_timestamp
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
        Consumer.on_write(
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
      assert attrs.object == table
      assert attrs.operation == :delete
      assert attrs.after == nil
      assert attrs.before == old_data
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
        Consumer.on_write(
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
        Consumer.on_write(
          state1,
          101,
          :update,
          "resources",
          %{"id" => resource_id, "account_id" => account.id, "name" => "test"},
          %{"id" => resource_id, "account_id" => account.id, "name" => "updated"}
        )

      assert map_size(state2.flush_buffer) == 2

      state3 =
        Consumer.on_write(
          state2,
          102,
          :delete,
          "resources",
          %{"id" => resource_id, "account_id" => account.id, "name" => "updated"},
          nil
        )

      assert map_size(state3.flush_buffer) == 3
      assert state3.flush_buffer[100].operation == :insert
      assert state3.flush_buffer[101].operation == :update
      assert state3.flush_buffer[102].operation == :delete
    end
  end

  describe "log_id allocation" do
    test "every row in a transaction shares the same commit_timestamp", %{
      account: account
    } do
      commit_timestamp = ~U[2026-05-26 12:00:00.001000Z]

      state =
        %{flush_buffer: %{}, seq_start: @seq_start, tenant_offsets: %{}}
        |> Consumer.on_begin(%{commit_timestamp: commit_timestamp})
        |> Consumer.on_write(
          200,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )
        |> Consumer.on_write(
          201,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert state.flush_buffer[200].timestamp == commit_timestamp
      assert state.flush_buffer[201].timestamp == commit_timestamp
    end

    test "successive writes for the same account get sequential per-tenant offsets", %{
      account: account,
      initial_state: initial_state
    } do
      data = fn -> %{"id" => Ecto.UUID.generate(), "account_id" => account.id} end

      state =
        initial_state
        |> Consumer.on_write(300, :insert, "resources", nil, data.())
        |> Consumer.on_write(301, :insert, "resources", nil, data.())
        |> Consumer.on_write(302, :insert, "resources", nil, data.())

      assert state.tenant_offsets[account.id] == 3
      assert state.flush_buffer[300].log_id == LogId.build_change_log(@seq_start, 0)
      assert state.flush_buffer[301].log_id == LogId.build_change_log(@seq_start, 1)
      assert state.flush_buffer[302].log_id == LogId.build_change_log(@seq_start, 2)
    end

    test "interleaved writes for three tenants each get their own dense offset progression",
         %{initial_state: initial_state} do
      a = account_fixture()
      b = account_fixture()
      c = account_fixture()

      writes = [
        {1000, a},
        {1001, a},
        {1002, b},
        {1003, a},
        {1004, c},
        {1005, b},
        {1006, c},
        {1007, a},
        {1008, b},
        {1009, c}
      ]

      state =
        Enum.reduce(writes, initial_state, fn {lsn, account}, acc ->
          Consumer.on_write(
            acc,
            lsn,
            :insert,
            "resources",
            nil,
            %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
          )
        end)

      # Each tenant got exactly the count of writes addressed to it...
      assert state.tenant_offsets[a.id] == 4
      assert state.tenant_offsets[b.id] == 3
      assert state.tenant_offsets[c.id] == 3

      # ...and the per-lsn log_ids encode the tenant's own offset progression,
      # not the global write order.
      expected = %{
        1000 => {a, 0},
        1001 => {a, 1},
        1002 => {b, 0},
        1003 => {a, 2},
        1004 => {c, 0},
        1005 => {b, 1},
        1006 => {c, 1},
        1007 => {a, 3},
        1008 => {b, 2},
        1009 => {c, 2}
      }

      for {lsn, {_account, offset}} <- expected do
        assert state.flush_buffer[lsn].log_id ==
                 LogId.build_change_log(@seq_start, offset)
      end
    end

    test "fresh on_begin (simulating consumer restart) seeds a new seq_start and resets offsets",
         %{account: account} do
      # Pre-restart "session": pre-seeded seq_start and offset counter.
      old_seq_start = @seq_start

      pre_restart =
        %{
          flush_buffer: %{},
          seq_start: old_seq_start,
          tenant_offsets: %{account.id => 5}
        }
        |> Consumer.on_begin(%{commit_timestamp: @commit_timestamp})
        |> Consumer.on_write(
          500,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert pre_restart.seq_start == old_seq_start

      assert pre_restart.flush_buffer[500].log_id ==
               LogId.build_change_log(old_seq_start, 5)

      # Post-restart: fresh empty state. on_begin seeds a brand-new seq_start
      # from the Postgres clock, and per-tenant offsets start over at 0.
      before_restart = Database.fetch_seq_start()

      post_restart =
        %{flush_buffer: %{}}
        |> Consumer.on_begin(%{commit_timestamp: @commit_timestamp})
        |> Consumer.on_write(
          600,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert post_restart.seq_start >= before_restart
      assert post_restart.seq_start > old_seq_start
      assert post_restart.tenant_offsets[account.id] == 1

      assert post_restart.flush_buffer[600].log_id ==
               LogId.build_change_log(post_restart.seq_start, 0)

      # Crucially, the new log_id sorts strictly after the old one.
      assert pre_restart.flush_buffer[500].log_id <
               post_restart.flush_buffer[600].log_id
    end

    test "raises FunctionClauseError when a tenant_offset would reach 2^40", %{
      account: account,
      initial_state: initial_state
    } do
      import Bitwise
      max_offset = bsl(1, 40)

      saturated_state = %{
        initial_state
        | tenant_offsets: %{account.id => max_offset - 1}
      }

      # The next write at the cap is still valid (offset 2^40 - 1).
      state =
        Consumer.on_write(
          saturated_state,
          700,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert state.tenant_offsets[account.id] == max_offset

      # The write after that overflows the LogId.build_change_log guard.
      assert_raise FunctionClauseError, fn ->
        Consumer.on_write(
          state,
          701,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )
      end
    end

    test "persists log_id and timestamp end-to-end through flush", %{
      account: account
    } do
      commit_timestamp = ~U[2026-05-26 12:00:00.999000Z]

      state =
        %{
          flush_buffer: %{},
          seq_start: @seq_start,
          tenant_offsets: %{}
        }
        |> Consumer.on_begin(%{commit_timestamp: commit_timestamp})
        |> Consumer.on_write(
          500,
          :insert,
          "resources",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test"}
        )
        |> Consumer.flush()

      assert state.flush_buffer == %{}

      change_log = Repo.one(from cl in ChangeLog, where: cl.lsn == 500)
      assert change_log.timestamp == commit_timestamp
      assert change_log.log_id == LogId.build_change_log(@seq_start, 0)
    end
  end

  describe "flush/1" do
    test "handles empty flush buffer" do
      state = %{flush_buffer: %{}}
      result_state = Consumer.flush(state)
      assert result_state == state
    end

    test "successfully flushes buffer and clears it", %{account: account} do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]

      attrs1 = %{
        log_id: LogId.build_change_log(@seq_start, 0),
        timestamp: committed_at,
        lsn: 100,
        object: "resources",
        operation: :insert,
        account_id: account.id,
        after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test1"},
        before: nil,
        vsn: 0,
        subject: nil
      }

      attrs2 = %{
        log_id: LogId.build_change_log(@seq_start, 1),
        timestamp: committed_at,
        lsn: 101,
        object: "resources",
        operation: :update,
        account_id: account.id,
        after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test2"},
        before: %{"id" => Ecto.UUID.generate(), "account_id" => account.id, "name" => "test1"},
        vsn: 0,
        subject: nil
      }

      state = %{
        flush_buffer: %{100 => attrs1, 101 => attrs2},
        seq_start: @seq_start,
        tenant_offsets: %{account.id => 2}
      }

      result_state = Consumer.flush(state)

      assert result_state.flush_buffer == %{}
      refute Map.has_key?(result_state, :seq_start)
      refute Map.has_key?(result_state, :tenant_offsets)

      change_logs = Repo.all(from cl in ChangeLog, where: cl.lsn in [100, 101], order_by: cl.lsn)
      assert length(change_logs) == 2

      [log1, log2] = change_logs
      assert log1.lsn == 100
      assert log1.operation == :insert
      assert log1.timestamp == committed_at
      assert log2.lsn == 101
      assert log2.operation == :update
      assert log2.timestamp == committed_at
    end

    test "flushes entries regardless of buffer key order", %{account: account} do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]

      attrs_map = %{
        400 => %{
          log_id: LogId.build_change_log(@seq_start, 0),
          timestamp: committed_at,
          lsn: 400,
          object: "resources",
          operation: :insert,
          account_id: account.id,
          after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          before: nil,
          vsn: 0,
          subject: nil
        },
        402 => %{
          log_id: LogId.build_change_log(@seq_start, 1),
          timestamp: committed_at,
          lsn: 402,
          object: "resources",
          operation: :insert,
          account_id: account.id,
          after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          before: nil,
          vsn: 0,
          subject: nil
        },
        401 => %{
          log_id: LogId.build_change_log(@seq_start, 2),
          timestamp: committed_at,
          lsn: 401,
          object: "resources",
          operation: :insert,
          account_id: account.id,
          after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
          before: nil,
          vsn: 0,
          subject: nil
        }
      }

      state = %{flush_buffer: attrs_map}
      result_state = Consumer.flush(state)

      assert result_state.flush_buffer == %{}

      assert [%ChangeLog{lsn: 400}, %ChangeLog{lsn: 401}, %ChangeLog{lsn: 402}] =
               Repo.all(from cl in ChangeLog, where: cl.lsn in [400, 401, 402], order_by: cl.lsn)
    end

    test "drops entries for a deleted account but persists valid entries in the batch", %{
      account: account
    } do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]
      missing_account_id = Ecto.UUID.generate()

      valid_entry = %{
        log_id: LogId.build_change_log(@seq_start, 0),
        timestamp: committed_at,
        lsn: 500,
        object: "resources",
        operation: :insert,
        account_id: account.id,
        after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
        before: nil,
        vsn: 0,
        subject: nil
      }

      dead_entry = %{
        log_id: LogId.build_change_log(@seq_start, 1),
        timestamp: committed_at,
        lsn: 501,
        object: "resources",
        operation: :insert,
        account_id: missing_account_id,
        after: %{"id" => Ecto.UUID.generate(), "account_id" => missing_account_id},
        before: nil,
        vsn: 0,
        subject: nil
      }

      state = %{flush_buffer: %{500 => valid_entry, 501 => dead_entry}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result_state = Consumer.flush(state)
          assert result_state.flush_buffer == %{}
        end)

      assert log =~ "Skipping 1 change log(s) because account no longer exists"

      # The valid entry survived; only the dead-account entry was dropped.
      assert [%ChangeLog{lsn: 500}] =
               Repo.all(from cl in ChangeLog, where: cl.lsn in [500, 501])
    end

    test "raises constraint violations that are not a missing account_id", %{account: account} do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]

      # Omitting the NOT NULL vsn column triggers a different Postgrex error. It
      # must surface as a crash rather than being silently dropped like the
      # missing-account case.
      entry = %{
        log_id: LogId.build_change_log(@seq_start, 0),
        timestamp: committed_at,
        lsn: 600,
        object: "resources",
        operation: :insert,
        account_id: account.id,
        after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
        before: nil,
        subject: nil
      }

      assert_raise Postgrex.Error, fn -> Database.bulk_insert([entry]) end
    end

    test "drops the batch seed so the next batch reseeds log_id ordering", %{account: account} do
      state =
        %{flush_buffer: %{}, seq_start: @seq_start, tenant_offsets: %{account.id => 5}}
        |> Consumer.flush()

      refute Map.has_key?(state, :seq_start)
      refute Map.has_key?(state, :tenant_offsets)

      # The next batch's first Begin reseeds from the shared Postgres clock,
      # so its log_ids sort after every previous batch's regardless of
      # which node produced them
      state = Consumer.on_begin(state, %{commit_timestamp: @commit_timestamp})
      assert state.seq_start > @seq_start
      assert state.tenant_offsets == %{}
    end

    test "skips replayed entries that already committed", %{account: account} do
      committed_at = ~U[2026-05-26 12:00:00.000000Z]

      entry = %{
        log_id: LogId.build_change_log(@seq_start, 0),
        timestamp: committed_at,
        lsn: 700,
        object: "resources",
        operation: :insert,
        account_id: account.id,
        after: %{"id" => Ecto.UUID.generate(), "account_id" => account.id},
        before: nil,
        vsn: 0,
        subject: nil
      }

      assert Database.bulk_insert([entry]) == 1
      # A crash before the slot advances replays the same WAL rows
      assert Database.bulk_insert([entry]) == 0

      assert [%ChangeLog{lsn: 700}] = Repo.all(from cl in ChangeLog, where: cl.lsn == 700)
    end
  end

  describe "edge cases" do
    test "logs error for writes without account_id", %{initial_state: initial_state} do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          result =
            Consumer.on_write(
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
  end
end
