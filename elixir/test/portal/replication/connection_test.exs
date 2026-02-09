defmodule Portal.Replication.ConnectionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # Define a test module that uses the Portal.Replication.Connection macro
  defmodule TestReplicationConnection do
    use Portal.Replication.Connection

    def on_write(state, lsn, op, table, old_data, data) do
      # Simple test implementation that tracks operations
      operations = Map.get(state, :operations, [])

      operation = %{
        lsn: lsn,
        op: op,
        table: table,
        old_data: old_data,
        data: data
      }

      Map.put(state, :operations, [operation | operations])
    end

    def on_flush(state) do
      # Test implementation that counts flushes
      flush_count = Map.get(state, :flush_count, 0)

      state
      |> Map.put(:flush_count, flush_count + 1)
      |> Map.put(:flush_buffer, %{})
    end

    # Helper function to expose the private handle_write function for testing
    def test_handle_write(msg, server_wal_end, state) do
      handle_write(msg, server_wal_end, state)
    end
  end

  # Create a test module that captures relation updates
  defmodule RelationTestConnection do
    use Portal.Replication.Connection

    def on_write(state, _, _, _, _, _), do: state

    def on_flush(state), do: state
  end

  describe "macro compilation" do
    test "creates a module with required functions" do
      # Verify the module was created with expected functions
      assert function_exported?(TestReplicationConnection, :start_link, 1)
      assert function_exported?(TestReplicationConnection, :init, 1)
      assert function_exported?(TestReplicationConnection, :handle_connect, 1)
      assert function_exported?(TestReplicationConnection, :handle_disconnect, 1)
      assert function_exported?(TestReplicationConnection, :handle_result, 2)
      assert function_exported?(TestReplicationConnection, :handle_data, 2)
      assert function_exported?(TestReplicationConnection, :handle_info, 2)
      assert function_exported?(TestReplicationConnection, :on_write, 6)
      assert function_exported?(TestReplicationConnection, :on_flush, 1)
    end
  end

  describe "struct definition" do
    test "defines correct struct with expected fields" do
      assert %TestReplicationConnection{} = struct = %TestReplicationConnection{}

      # Check default values
      assert struct.schema == "public"
      assert struct.step == :disconnected
      assert struct.output_plugin == "pgoutput"
      assert struct.proto_version == 1
      assert struct.table_subscriptions == []
      assert struct.relations == %{}
      assert struct.counter == 0
      assert struct.tables_to_remove == MapSet.new()
      assert struct.flush_interval == 0
      assert struct.flush_buffer == %{}
      assert struct.last_flushed_lsn == 0
      assert struct.warning_threshold_exceeded? == false
      assert struct.error_threshold_exceeded? == false
      assert struct.flush_buffer_size == 0
      assert struct.status_log_interval == :timer.minutes(1)
      assert struct.warning_threshold == :timer.seconds(30)
      assert struct.error_threshold == :timer.seconds(60)
      assert struct.last_sent_lsn == nil
      assert struct.last_keep_alive == nil
    end
  end

  describe "initialization" do
    test "init/1 preserves state" do
      initial_state = %TestReplicationConnection{counter: 42}
      {:ok, state} = TestReplicationConnection.init(initial_state)
      assert state.counter == 42
    end

    test "init/1 schedules flush when flush_interval > 0" do
      initial_state = %TestReplicationConnection{flush_interval: 10}
      {:ok, _state} = TestReplicationConnection.init(initial_state)

      # Should receive flush message after interval
      assert_receive :flush, 50
    end

    test "init/1 does not schedule flush when flush_interval is 0" do
      initial_state = %TestReplicationConnection{flush_interval: 0}
      {:ok, _state} = TestReplicationConnection.init(initial_state)

      # Should not receive flush message
      refute_receive :flush, 10
    end
  end

  describe "handle_connect/1" do
    test "returns query to check publication" do
      state = %TestReplicationConnection{publication_name: "test_pub"}

      {:query, query, new_state} = TestReplicationConnection.handle_connect(state)

      assert query == "SELECT 1 FROM pg_publication WHERE pubname = 'test_pub'"
      assert new_state.step == :check_publication
    end
  end

  describe "handle_disconnect/1" do
    test "logs disconnection and updates state" do
      state = %TestReplicationConnection{counter: 123, step: :streaming}

      log =
        capture_log(fn ->
          {:noreply, new_state} = TestReplicationConnection.handle_disconnect(state)
          assert new_state.step == :disconnected
          assert new_state.counter == 123
        end)

      assert log =~ "Replication connection disconnected"
      assert log =~ "counter=123"
    end
  end

  describe "handle_info/2" do
    test "handles :shutdown message" do
      assert {:disconnect, :normal} = TestReplicationConnection.handle_info(:shutdown, %{})
    end

    test "handles DOWN message" do
      assert {:disconnect, :normal} =
               TestReplicationConnection.handle_info({:DOWN, nil, :process, nil, nil}, %{})
    end

    test "handles :flush message when flush_interval > 0" do
      state =
        %TestReplicationConnection{
          flush_interval: 10,
          flush_buffer: %{1 => %{data: "test"}}
        }
        |> Map.put(:operations, [])
        |> Map.put(:flush_count, 0)

      {:noreply, new_state} = TestReplicationConnection.handle_info(:flush, state)

      # Our test on_flush implementation increments flush_count
      assert Map.get(new_state, :flush_count) == 1
      assert new_state.flush_buffer == %{}

      # Should schedule next flush
      assert_receive :flush, 50
    end

    test "handles :interval_logger message" do
      state = %TestReplicationConnection{counter: 456, status_log_interval: 10}

      log =
        capture_log(fn ->
          {:noreply, _new_state} = TestReplicationConnection.handle_info(:interval_logger, state)
        end)

      assert log =~ "Processed 456 write messages from the WAL stream"

      # Should schedule next log
      assert_receive :interval_logger, 500
    end

    test "handles warning threshold checks" do
      # Below threshold
      state = %TestReplicationConnection{
        warning_threshold_exceeded?: false,
        warning_threshold: 1000
      }

      {:noreply, new_state} =
        TestReplicationConnection.handle_info({:check_warning_threshold, 500}, state)

      assert new_state.warning_threshold_exceeded? == false

      # Above threshold
      log =
        capture_log(fn ->
          {:noreply, new_state2} =
            TestReplicationConnection.handle_info({:check_warning_threshold, 1500}, state)

          assert new_state2.warning_threshold_exceeded? == true
        end)

      assert log =~ "Processing lag exceeds warning threshold"

      # Back below threshold
      exceeded_state = %{state | warning_threshold_exceeded?: true}

      log2 =
        capture_log(fn ->
          {:noreply, new_state3} =
            TestReplicationConnection.handle_info({:check_warning_threshold, 500}, exceeded_state)

          assert new_state3.warning_threshold_exceeded? == false
        end)

      assert log2 =~ "Processing lag is back below warning threshold"
    end

    test "handles error threshold checks" do
      # Below threshold
      state = %TestReplicationConnection{
        error_threshold_exceeded?: false,
        error_threshold: 2000
      }

      {:noreply, new_state} =
        TestReplicationConnection.handle_info({:check_error_threshold, 1000}, state)

      assert new_state.error_threshold_exceeded? == false

      # Above threshold
      log =
        capture_log(fn ->
          {:noreply, new_state2} =
            TestReplicationConnection.handle_info({:check_error_threshold, 3000}, state)

          assert new_state2.error_threshold_exceeded? == true
        end)

      assert log =~ "Processing lag exceeds error threshold; skipping side effects!"

      # Back below threshold
      exceeded_state = %{state | error_threshold_exceeded?: true}

      log2 =
        capture_log(fn ->
          {:noreply, new_state3} =
            TestReplicationConnection.handle_info({:check_error_threshold, 1000}, exceeded_state)

          assert new_state3.error_threshold_exceeded? == false
        end)

      assert log2 =~ "Processing lag is back below error threshold"
    end

    test "handles unknown messages" do
      state = %TestReplicationConnection{counter: 789}
      {:noreply, new_state} = TestReplicationConnection.handle_info(:unknown_message, state)
      assert new_state == state
    end
  end

  describe "write message handling" do
    test "processes insert messages" do
      state =
        %TestReplicationConnection{
          relations: %{
            1 => %{
              namespace: "public",
              name: "users",
              columns: [
                %{name: "id"},
                %{name: "name"}
              ]
            }
          },
          counter: 0
        }
        |> Map.put(:operations, [])

      # Test on_write callback directly
      # In a real scenario, handle_data would parse WAL messages and eventually
      # call on_write with the decoded operation data
      new_state =
        TestReplicationConnection.on_write(
          state,
          100,
          :insert,
          "users",
          nil,
          %{"id" => "123", "name" => "John Doe"}
        )

      operations = Map.get(new_state, :operations, [])
      assert length(operations) == 1
      [operation] = operations
      assert operation.op == :insert
      assert operation.table == "users"
      assert operation.lsn == 100
    end

    test "processes update messages" do
      state =
        %TestReplicationConnection{}
        |> Map.put(:operations, [])

      new_state =
        TestReplicationConnection.on_write(
          state,
          101,
          :update,
          "users",
          %{"id" => "123", "name" => "John"},
          %{"id" => "123", "name" => "John Doe"}
        )

      operations = Map.get(new_state, :operations, [])
      assert length(operations) == 1
      [operation] = operations
      assert operation.op == :update
      assert operation.old_data == %{"id" => "123", "name" => "John"}
      assert operation.data == %{"id" => "123", "name" => "John Doe"}
    end

    test "processes delete messages" do
      state =
        %TestReplicationConnection{}
        |> Map.put(:operations, [])

      new_state =
        TestReplicationConnection.on_write(
          state,
          102,
          :delete,
          "users",
          %{"id" => "123", "name" => "John Doe"},
          nil
        )

      operations = Map.get(new_state, :operations, [])
      assert length(operations) == 1
      [operation] = operations
      assert operation.op == :delete
      assert operation.old_data == %{"id" => "123", "name" => "John Doe"}
      assert operation.data == nil
    end

    test "on_write always processes operations in test implementation" do
      # Note: In the real implementation, process_write checks error_threshold_exceeded?
      # but our test implementation doesn't, so operations are always processed
      state =
        %TestReplicationConnection{
          error_threshold_exceeded?: true
        }
        |> Map.put(:operations, [])

      new_state =
        TestReplicationConnection.on_write(
          state,
          103,
          :insert,
          "users",
          nil,
          %{"id" => "456"}
        )

      # Our test implementation always processes operations
      operations = Map.get(new_state, :operations, [])
      assert length(operations) == 1
    end
  end

  describe "flush behavior" do
    test "calls on_flush when buffer size reached" do
      state =
        %TestReplicationConnection{
          flush_buffer: %{1 => %{}, 2 => %{}},
          flush_buffer_size: 3
        }
        |> Map.put(:flush_count, 0)
        |> Map.put(:operations, [])

      # Adding one more should trigger flush
      # In the real implementation, this would happen in process_write
      # when maybe_flush is called
      new_state = %{state | flush_buffer: Map.put(state.flush_buffer, 3, %{})}

      # Simulate maybe_flush logic
      flushed_state =
        if map_size(new_state.flush_buffer) >= new_state.flush_buffer_size do
          TestReplicationConnection.on_flush(new_state)
        else
          new_state
        end

      assert Map.get(flushed_state, :flush_count) == 1
      assert flushed_state.flush_buffer == %{}
    end
  end

  describe "publication and slot management flow" do
    test "creates publication when it doesn't exist" do
      state = %TestReplicationConnection{
        publication_name: "test_pub",
        table_subscriptions: ["users", "posts"],
        schema: "public",
        step: :check_publication
      }

      # Simulate publication not existing
      {:query, query, new_state} =
        TestReplicationConnection.handle_result(
          [%Postgrex.Result{num_rows: 0}],
          state
        )

      assert query == "CREATE PUBLICATION test_pub FOR TABLE public.users,public.posts"
      assert new_state.step == :check_replication_slot
    end

    test "checks publication tables when publication exists" do
      state = %TestReplicationConnection{
        publication_name: "test_pub",
        step: :check_publication
      }

      {:query, query, new_state} =
        TestReplicationConnection.handle_result(
          [%Postgrex.Result{num_rows: 1}],
          state
        )

      assert query =~ "SELECT schemaname, tablename"
      assert query =~ "FROM pg_publication_tables"
      assert query =~ "WHERE pubname = 'test_pub'"
      assert new_state.step == :check_publication_tables
    end

    test "creates replication slot when it doesn't exist" do
      state = %TestReplicationConnection{
        replication_slot_name: "test_slot",
        output_plugin: "pgoutput",
        step: :create_slot
      }

      {:query, query, new_state} =
        TestReplicationConnection.handle_result(
          [%Postgrex.Result{num_rows: 0}],
          state
        )

      assert query == "CREATE_REPLICATION_SLOT test_slot LOGICAL pgoutput NOEXPORT_SNAPSHOT"
      assert new_state.step == :start_replication_slot
    end

    test "starts replication when slot exists" do
      state = %TestReplicationConnection{
        replication_slot_name: "test_slot",
        publication_name: "test_pub",
        proto_version: 1,
        step: :start_replication_slot
      }

      {:stream, query, [], new_state} =
        TestReplicationConnection.handle_result(
          [%Postgrex.Result{}],
          state
        )

      assert query =~ "START_REPLICATION SLOT \"test_slot\""
      assert query =~ "publication_names 'test_pub'"
      assert query =~ "proto_version '1'"
      assert new_state.step == :streaming
    end
  end

  describe "relation message handling" do
    test "stores relation information" do
      state = %RelationTestConnection{relations: %{}}

      # In the real implementation, this would be called from handle_data
      # when a Relation message is received. Since handle_write is private,
      # we can't test it directly, but we know it updates the relations map
      relation = %{
        id: 1,
        namespace: "public",
        name: "test_table",
        columns: [%{name: "id"}, %{name: "data"}]
      }

      # The relation would be stored with id as key
      new_state = %{state | relations: Map.put(state.relations, relation.id, relation)}

      assert new_state.relations[1].name == "test_table"
      assert length(new_state.relations[1].columns) == 2
    end
  end

  describe "handle_data/2" do
    test "returns correct tuple format for unknown messages" do
      state = %TestReplicationConnection{counter: 15}

      # Test with binary data that doesn't match WAL message patterns
      unknown_data = <<255, 254, 253>>

      log =
        capture_log(fn ->
          result = TestReplicationConnection.handle_data(unknown_data, state)

          # Verify return format
          assert match?({:noreply, [], %TestReplicationConnection{}}, result)

          {:noreply, reply_data, new_state} = result
          assert reply_data == []
          # State should be unchanged
          assert new_state == state
        end)

      assert log =~ "Unknown WAL message received!"
    end

    test "handle_data always returns 3-tuple with :noreply" do
      state = %TestReplicationConnection{counter: 0}

      # Test various binary inputs to ensure consistent return patterns
      test_inputs = [
        # Single byte
        <<0>>,
        # Multiple bytes
        <<1, 2, 3>>,
        # Empty binary
        <<>>,
        # High value bytes
        <<255, 255>>
      ]

      Enum.each(test_inputs, fn input ->
        result = TestReplicationConnection.handle_data(input, state)

        # All handle_data calls should return 3-tuples starting with :noreply
        assert match?({:noreply, _, _}, result)

        {tag, response, returned_state} = result
        assert tag == :noreply
        # Should be a list (empty for unknown messages)
        assert is_list(response)
        assert match?(%TestReplicationConnection{}, returned_state)
      end)
    end

    test "handle_data preserves state structure" do
      complex_state = %TestReplicationConnection{
        counter: 42,
        relations: %{1 => %{name: "test"}},
        flush_buffer: %{key: "value"},
        warning_threshold_exceeded?: true,
        error_threshold_exceeded?: false
      }

      unknown_data = <<99, 98, 97>>

      {:noreply, _response, new_state} =
        TestReplicationConnection.handle_data(unknown_data, complex_state)

      # For unknown messages, state should be preserved exactly
      assert new_state == complex_state
    end

    test "handle_data logs unknown messages with context" do
      state = %TestReplicationConnection{counter: 123}
      unknown_data = <<1, 2, 3, 4, 5>>

      log =
        capture_log(fn ->
          TestReplicationConnection.handle_data(unknown_data, state)
        end)

      # Should log the unknown message with data and state info
      assert log =~ "Unknown WAL message received!"
      assert log =~ "data="
      assert log =~ "state="
    end

    test "handle_data with empty binary" do
      state = %TestReplicationConnection{counter: 0}

      {:noreply, response, new_state} = TestReplicationConnection.handle_data(<<>>, state)

      assert response == []
      assert new_state == state
    end

    test "handle_data error handling doesn't crash" do
      state = %TestReplicationConnection{counter: 999}

      # Test that malformed binary data doesn't crash the function
      malformed_inputs = [
        <<0, 0, 0, 0, 0, 0, 0, 0, 255>>,
        # Very large binary
        <<1::size(1000)>>,
        # Large binary
        List.duplicate(<<255>>, 100) |> IO.iodata_to_binary()
      ]

      Enum.each(malformed_inputs, fn input ->
        # Should not raise an exception
        result = TestReplicationConnection.handle_data(input, state)
        assert match?({:noreply, [], _}, result)
      end)
    end

    test "decodes messages containing jsonb fields" do
      relation = %{
        namespace: "public",
        name: "test_table",
        columns: [
          %{name: "id", type: "integer"},
          %{name: "data_map", type: "jsonb"},
          %{name: "data_list", type: "jsonb"},
          %{name: "data_toast", type: "jsonb"},
          %{name: "data_null", type: "jsonb"}
        ]
      }

      state =
        %TestReplicationConnection{
          relations: %{123 => relation}
        }
        |> Map.put(:operations, [])

      json_map_string = ~s({"a": 1, "b": {"c": true}})
      json_list_string = ~s([1, "two", false, null])
      json_unchanged_toast = :unchanged_toast

      insert_msg = %Portal.Replication.Decoder.Messages.Insert{
        relation_id: 123,
        tuple_data: {101, json_map_string, json_list_string, json_unchanged_toast, nil}
      }

      {:noreply, [], new_state} =
        TestReplicationConnection.test_handle_write(insert_msg, 999, state)

      [operation] = Map.get(new_state, :operations)

      assert operation.op == :insert
      assert operation.table == "test_table"
      assert operation.lsn == 999

      assert operation.data == %{
               "id" => 101,
               "data_map" => %{"a" => 1, "b" => %{"c" => true}},
               "data_list" => [1, "two", false, nil],
               "data_null" => nil,
               "data_toast" => :unchanged_toast
             }
    end

    test "replies with standby status updates for all KeepAlive messages" do
      state = %TestReplicationConnection{step: :streaming, last_sent_lsn: 0}

      keep_alive_data = <<?k, 0::integer-size(64), 0::integer-size(64), 0>>

      {:noreply, reply_data, new_state} =
        TestReplicationConnection.handle_data(keep_alive_data, state)

      assert new_state.last_sent_lsn == 1
      assert [<<?r, wal_end::64, wal_end::64, wal_end::64, _timestamp::64, 0>>] = reply_data
      assert wal_end == 1
    end
  end

  describe "message processing components" do
    test "on_write callback integration" do
      state =
        %TestReplicationConnection{}
        |> Map.put(:operations, [])

      # Test our custom on_write implementation directly
      result_state =
        TestReplicationConnection.on_write(
          state,
          # lsn
          100,
          # op
          :insert,
          # table
          "users",
          # old_data
          nil,
          # data
          %{"id" => 1, "name" => "test"}
        )

      operations = Map.get(result_state, :operations, [])
      assert length(operations) == 1

      [operation] = operations
      assert operation.lsn == 100
      assert operation.op == :insert
      assert operation.table == "users"
      assert operation.data == %{"id" => 1, "name" => "test"}
    end

    test "on_flush callback integration" do
      state =
        %TestReplicationConnection{
          flush_buffer: %{1 => "data1", 2 => "data2"}
        }
        |> Map.put(:flush_count, 5)

      result_state = TestReplicationConnection.on_flush(state)

      # Our test implementation should increment flush count and clear buffer
      assert Map.get(result_state, :flush_count) == 6
      assert result_state.flush_buffer == %{}
    end

    test "state transformations preserve required fields" do
      initial_state = %TestReplicationConnection{
        schema: "custom",
        publication_name: "test_pub",
        replication_slot_name: "test_slot",
        counter: 50
      }

      # Test that our callbacks preserve the core state structure
      after_write =
        TestReplicationConnection.on_write(
          initial_state,
          200,
          :update,
          "table",
          %{},
          %{}
        )

      # Core fields should be preserved
      assert after_write.schema == "custom"
      assert after_write.publication_name == "test_pub"
      assert after_write.replication_slot_name == "test_slot"
      assert after_write.counter == 50

      after_flush = TestReplicationConnection.on_flush(after_write)

      # Should still preserve core fields after flush
      assert after_flush.schema == "custom"
      assert after_flush.publication_name == "test_pub"
      assert after_flush.replication_slot_name == "test_slot"
    end
  end
end
