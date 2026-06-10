defmodule Portal.SessionLogs.ReplicationConnectionTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  alias Portal.SessionLogs.ReplicationConnection
  alias Portal.SessionLogs.ReplicationConnection.Database
  alias Portal.SessionLog
  alias Portal.Types.EventId

  @commit_timestamp ~U[2026-06-09 12:00:00.123000Z]

  setup do
    tables =
      Application.fetch_env!(:portal, Portal.SessionLogs.ReplicationConnection)
      |> Keyword.fetch!(:table_subscriptions)

    account = account_fixture()

    # In production every Write is preceded by a Begin that populates
    # commit_timestamp, so seed it here for on_write/6 tests.
    initial_state = %{
      flush_buffer: %{},
      commit_timestamp: @commit_timestamp
    }

    %{account: account, tables: tables, initial_state: initial_state}
  end

  describe "configured tables" do
    test "subscribes to exactly the session tables", %{tables: tables} do
      assert Enum.sort(tables) == ~w[client_sessions gateway_sessions portal_sessions]
    end
  end

  describe "on_begin/2" do
    test "captures commit_timestamp on the transaction state" do
      commit_timestamp = ~U[2026-06-09 12:00:00.123000Z]
      state = %{flush_buffer: %{}}

      result_state =
        ReplicationConnection.on_begin(state, %{commit_timestamp: commit_timestamp})

      assert result_state.commit_timestamp == commit_timestamp
    end
  end

  describe "on_write/6" do
    test "buffers client session inserts with extracted columns", %{
      account: account,
      initial_state: initial_state
    } do
      device_id = Ecto.UUID.generate()
      client_token_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "device_id" => device_id,
        "actor_id" => actor_id,
        "actor_email" => "user@example.com",
        "client_token_id" => client_token_id,
        "user_agent" => "testclient/1.0",
        "remote_ip" => "189.172.73.1",
        "remote_ip_location_region" => "US",
        "remote_ip_location_city" => "San Francisco",
        "remote_ip_location_lat" => "37.7749",
        "remote_ip_location_lon" => "-122.4194",
        "timestamp" => "2026-06-09 11:59:58.5+00"
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12345,
          :insert,
          "client_sessions",
          nil,
          data
        )

      assert map_size(result_state.flush_buffer) == 1
      assert result_state.commit_timestamp == @commit_timestamp

      attrs = result_state.flush_buffer[12345]
      assert attrs.lsn == 12345
      assert attrs.context == :client
      assert attrs.account_id == account.id
      assert attrs.actor_id == actor_id
      assert attrs.actor_email == "user@example.com"
      assert attrs.device_id == device_id
      assert attrs.token_id == client_token_id
      assert attrs.auth_provider_id == nil
      assert attrs.user_agent == "testclient/1.0"
      assert attrs.remote_ip == %Postgrex.INET{address: {189, 172, 73, 1}}
      assert attrs.remote_ip_location_region == "US"
      assert attrs.remote_ip_location_city == "San Francisco"
      assert attrs.remote_ip_location_lat == 37.7749
      assert attrs.remote_ip_location_lon == -122.4194
      assert attrs.timestamp == ~U[2026-06-09 11:59:58.500000Z]
      assert String.starts_with?(attrs.event_id, "5")
    end

    test "buffers gateway session inserts with the gateway token", %{
      account: account,
      initial_state: initial_state
    } do
      gateway_token_id = Ecto.UUID.generate()

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "device_id" => Ecto.UUID.generate(),
        "gateway_token_id" => gateway_token_id
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12346,
          :insert,
          "gateway_sessions",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12346]
      assert attrs.context == :gateway
      assert attrs.token_id == gateway_token_id
      assert attrs.remote_ip == nil
      assert attrs.remote_ip_location_lat == nil

      # Rows written by code predating the session `timestamp` column fall
      # back to the WAL commit timestamp.
      assert attrs.timestamp == @commit_timestamp
    end

    test "buffers portal session inserts with actor and auth provider", %{
      account: account,
      initial_state: initial_state
    } do
      actor_id = Ecto.UUID.generate()
      auth_provider_id = Ecto.UUID.generate()

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "actor_id" => actor_id,
        "actor_email" => "admin@example.com",
        "auth_provider_id" => auth_provider_id,
        "user_agent" => "Mozilla/5.0",
        "remote_ip" => "2607:f8b0::1"
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12347,
          :insert,
          "portal_sessions",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12347]
      assert attrs.context == :portal
      assert attrs.actor_id == actor_id
      assert attrs.actor_email == "admin@example.com"
      assert attrs.auth_provider_id == auth_provider_id
      assert attrs.device_id == nil
      assert attrs.token_id == nil
      assert attrs.remote_ip == %Postgrex.INET{address: {0x2607, 0xF8B0, 0, 0, 0, 0, 0, 1}}
    end

    test "ignores updates and deletes of session tables", %{
      account: account,
      initial_state: initial_state
    } do
      id = Ecto.UUID.generate()
      old_data = %{"id" => id, "account_id" => account.id}
      data = %{"id" => id, "account_id" => account.id, "user_agent" => "updated"}

      state =
        ReplicationConnection.on_write(
          initial_state,
          12348,
          :update,
          "gateway_sessions",
          old_data,
          data
        )

      assert state == initial_state

      state =
        ReplicationConnection.on_write(
          initial_state,
          12349,
          :delete,
          "portal_sessions",
          old_data,
          nil
        )

      assert state == initial_state
    end

    test "nils out unparseable typed fields instead of crashing", %{
      account: account,
      initial_state: initial_state
    } do
      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "remote_ip" => "not an ip",
        "remote_ip_location_lat" => "not a float",
        "timestamp" => "not a timestamp"
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12350,
          :insert,
          "client_sessions",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12350]
      assert attrs.remote_ip == nil
      assert attrs.remote_ip_location_lat == nil
      assert attrs.timestamp == @commit_timestamp
    end

    test "parses an offset-less timestamp as UTC", %{
      account: account,
      initial_state: initial_state
    } do
      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "timestamp" => "2026-06-09 11:59:58.5"
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12351,
          :insert,
          "client_sessions",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12351]
      assert attrs.timestamp == ~U[2026-06-09 11:59:58.500000Z]
    end

    test "passes already-typed values through unchanged", %{
      account: account,
      initial_state: initial_state
    } do
      timestamp = ~U[2026-06-09 11:59:58.500000Z]

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "timestamp" => timestamp,
        "remote_ip_location_lat" => 37.5
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12352,
          :insert,
          "client_sessions",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12352]
      assert attrs.timestamp == timestamp
      assert attrs.remote_ip_location_lat == 37.5
    end

    test "nils out typed fields with values that are neither text nor typed", %{
      account: account,
      initial_state: initial_state
    } do
      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "timestamp" => 123,
        "remote_ip_location_lat" => 42
      }

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          12353,
          :insert,
          "client_sessions",
          nil,
          data
        )

      attrs = result_state.flush_buffer[12353]
      assert attrs.timestamp == @commit_timestamp
      assert attrs.remote_ip_location_lat == nil
    end

    test "preserves existing buffer items", %{account: account, initial_state: initial_state} do
      existing_lsn = 100

      existing_item = %{
        event_id: EventId.build_session_log(),
        timestamp: @commit_timestamp,
        lsn: existing_lsn,
        account_id: account.id,
        context: :client
      }

      initial_state = %{initial_state | flush_buffer: %{existing_lsn => existing_item}}

      new_lsn = 101

      result_state =
        ReplicationConnection.on_write(
          initial_state,
          new_lsn,
          :insert,
          "client_sessions",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert map_size(result_state.flush_buffer) == 2
      assert result_state.flush_buffer[existing_lsn] == existing_item
      assert Map.has_key?(result_state.flush_buffer, new_lsn)
    end

    test "does not rebuffer an lsn that is already buffered", %{
      account: account,
      initial_state: initial_state
    } do
      lsn = 200

      state =
        ReplicationConnection.on_write(
          initial_state,
          lsn,
          :insert,
          "client_sessions",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      buffered = state.flush_buffer[lsn]

      replayed_state =
        ReplicationConnection.on_write(
          state,
          lsn,
          :insert,
          "client_sessions",
          nil,
          %{"id" => Ecto.UUID.generate(), "account_id" => account.id}
        )

      assert replayed_state.flush_buffer[lsn] == buffered
      assert map_size(replayed_state.flush_buffer) == 1
    end

    test "logs error for writes to unexpected tables", %{initial_state: initial_state} do
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
              %{"id" => Ecto.UUID.generate(), "name" => "not a session"}
            )

          assert result == initial_state
        end)

      assert log =~ "Unexpected write operation!"
      assert log =~ "lsn=500"
    end
  end

  describe "on_flush/1" do
    test "handles empty flush buffer" do
      state = %{flush_buffer: %{}}
      result_state = ReplicationConnection.on_flush(state)
      assert result_state == state
    end

    test "persists buffered entries end-to-end and clears the buffer", %{account: account} do
      commit_timestamp = ~U[2026-06-09 12:00:00.999000Z]
      device_id = Ecto.UUID.generate()

      state =
        %{flush_buffer: %{}, last_flushed_lsn: 0}
        |> ReplicationConnection.on_begin(%{commit_timestamp: commit_timestamp})
        |> ReplicationConnection.on_write(
          500,
          :insert,
          "client_sessions",
          nil,
          %{
            "id" => Ecto.UUID.generate(),
            "account_id" => account.id,
            "device_id" => device_id,
            "user_agent" => "testclient/1.0",
            "remote_ip" => "189.172.73.1",
            "remote_ip_location_lat" => "37.7749"
          }
        )
        |> ReplicationConnection.on_flush()

      assert state.flush_buffer == %{}
      assert state.last_flushed_lsn == 500

      session_log = Repo.one(from sl in SessionLog, where: sl.lsn == 500)
      assert session_log.timestamp == commit_timestamp
      assert session_log.context == :client
      assert session_log.device_id == device_id
      assert session_log.user_agent == "testclient/1.0"
      assert session_log.remote_ip == %Postgrex.INET{address: {189, 172, 73, 1}}
      assert session_log.remote_ip_location_lat == 37.7749
      assert String.starts_with?(session_log.event_id, "5")
    end

    test "calculates last_flushed_lsn correctly as max LSN", %{account: account} do
      committed_at = ~U[2026-06-09 12:00:00.000000Z]

      attrs_map =
        for lsn <- [400, 402, 401], into: %{} do
          {lsn,
           %{
             event_id: EventId.build_session_log(),
             timestamp: committed_at,
             lsn: lsn,
             account_id: account.id,
             context: :client
           }}
        end

      state = %{flush_buffer: attrs_map, last_flushed_lsn: 399}
      result_state = ReplicationConnection.on_flush(state)

      assert result_state.last_flushed_lsn == 402
      assert result_state.flush_buffer == %{}
    end

    test "drops entries for a deleted account but persists valid entries in the batch", %{
      account: account
    } do
      committed_at = ~U[2026-06-09 12:00:00.000000Z]
      missing_account_id = Ecto.UUID.generate()

      valid_entry = %{
        event_id: EventId.build_session_log(),
        timestamp: committed_at,
        lsn: 500,
        account_id: account.id,
        context: :client
      }

      dead_entry = %{
        event_id: EventId.build_session_log(),
        timestamp: committed_at,
        lsn: 501,
        account_id: missing_account_id,
        context: :client
      }

      state = %{
        flush_buffer: %{500 => valid_entry, 501 => dead_entry},
        last_flushed_lsn: 499
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result_state = ReplicationConnection.on_flush(state)

          # LSN advances past the whole batch so we don't replay the dead entry
          # forever, and the buffer is cleared.
          assert result_state.last_flushed_lsn == 501
          assert result_state.flush_buffer == %{}
        end)

      assert log =~ "Skipping 1 session log(s) because account no longer exists"

      # The valid entry survived; only the dead-account entry was dropped.
      assert [%SessionLog{lsn: 500}] =
               Repo.all(from sl in SessionLog, where: sl.lsn in [500, 501])
    end

    test "reraises constraint violations that are not a missing account_id", %{account: account} do
      committed_at = ~U[2026-06-09 12:00:00.000000Z]

      # Omitting the NOT NULL context column triggers a different Postgrex
      # error. It must surface as a crash rather than being silently dropped
      # like the missing-account case.
      entry = %{
        event_id: EventId.build_session_log(),
        timestamp: committed_at,
        lsn: 600,
        account_id: account.id
      }

      assert_raise Postgrex.Error, fn -> Database.bulk_insert([entry]) end
    end

    test "deduplicates on lsn conflicts", %{account: account} do
      committed_at = ~U[2026-06-09 12:00:00.000000Z]

      entry = %{
        event_id: EventId.build_session_log(),
        timestamp: committed_at,
        lsn: 700,
        account_id: account.id,
        context: :client
      }

      assert {1, 0} = Database.bulk_insert([entry])

      replayed = %{entry | event_id: EventId.build_session_log()}
      assert {0, 0} = Database.bulk_insert([replayed])

      assert [%SessionLog{lsn: 700}] = Repo.all(from sl in SessionLog, where: sl.lsn == 700)
    end

    test "returns zero inserts when every entry references a missing account" do
      committed_at = ~U[2026-06-09 12:00:00.000000Z]
      missing_account_id = Ecto.UUID.generate()

      entries =
        for lsn <- [800, 801] do
          %{
            event_id: EventId.build_session_log(),
            timestamp: committed_at,
            lsn: lsn,
            account_id: missing_account_id,
            context: :client
          }
        end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {0, 2} = Database.bulk_insert(entries)
        end)

      assert log =~ "Skipping 2 session log(s) because account no longer exists"
    end
  end

  describe "Database.split_missing_account/2" do
    test "raises when the violating account_id is not in the batch" do
      entry = %{account_id: Ecto.UUID.generate()}

      assert_raise RuntimeError, ~r/not present in the batch/, fn ->
        Database.split_missing_account([entry], Ecto.UUID.generate())
      end
    end
  end

  describe "Database.missing_account_id!/1" do
    test "extracts the account_id from the FK violation detail" do
      account_id = Ecto.UUID.generate()

      detail = ~s|Key (account_id)=(#{account_id}) is not present in table "accounts".|

      assert Database.missing_account_id!(%{detail: detail}) == account_id
    end

    test "raises when the detail does not match the expected format" do
      assert_raise RuntimeError, ~r/could not parse account_id/, fn ->
        Database.missing_account_id!(%{detail: "some unexpected format"})
      end
    end

    test "raises when there is no usable detail" do
      assert_raise RuntimeError, ~r/no usable detail/, fn ->
        Database.missing_account_id!(%{detail: nil})
      end
    end
  end
end
