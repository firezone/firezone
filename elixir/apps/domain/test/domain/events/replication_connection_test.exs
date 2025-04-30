defmodule Domain.Events.ReplicationConnectionTest do
  # Only one ReplicationConnection should be started in the cluster
  use ExUnit.Case, async: false

  alias Domain.Events.ReplicationConnection

  # Used to test callbacks, not used for live connection
  @mock_state %ReplicationConnection{
    schema: "test_schema",
    step: :disconnected,
    publication_name: "test_pub",
    replication_slot_name: "test_slot",
    output_plugin: "pgoutput",
    proto_version: 1,
    table_subscriptions: ["accounts", "resources"],
    relations: %{}
  }

  # Used to test live connection
  setup_all do
    config =
      Application.fetch_env!(:domain, Domain.Events.ReplicationConnection)

    instance = struct(Domain.Events.ReplicationConnection, config)

    child_spec = %{
      id: Domain.Events.ReplicationConnection,
      start: {Domain.Events.ReplicationConnection, :start_link, [instance]},
      restart: :transient
    }

    {:ok, pid} = start_supervised(child_spec)

    {:ok, pid: pid}
  end

  describe "handle_connect/1 callback" do
    test "handle_connect initiates publication check" do
      state = @mock_state
      expected_query = "SELECT 1 FROM pg_publication WHERE pubname = '#{state.publication_name}'"
      expected_next_state = %{state | step: :create_publication}

      assert {:query, ^expected_query, ^expected_next_state} =
               ReplicationConnection.handle_connect(state)
    end
  end

  describe "handle_result/2 callback" do
    test "handle_result transitions from create_publication to create_replication_slot when publication exists" do
      state = %{@mock_state | step: :create_publication}
      result = [%Postgrex.Result{num_rows: 1}]

      expected_query =
        "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

      expected_next_state = %{state | step: :create_replication_slot}

      assert {:query, ^expected_query, ^expected_next_state} =
               ReplicationConnection.handle_result(result, state)
    end

    test "handle_result transitions from create_replication_slot to start_replication_slot when slot exists" do
      state = %{@mock_state | step: :create_replication_slot}
      result = [%Postgrex.Result{num_rows: 1}]

      expected_query = "SELECT 1"
      expected_next_state = %{state | step: :start_replication_slot}

      assert {:query, ^expected_query, ^expected_next_state} =
               ReplicationConnection.handle_result(result, state)
    end

    test "handle_result transitions from start_replication_slot to streaming" do
      state = %{@mock_state | step: :start_replication_slot}
      result = [%Postgrex.Result{num_rows: 1}]

      expected_stream_query =
        "START_REPLICATION SLOT \"#{state.replication_slot_name}\" LOGICAL 0/0  (proto_version '#{state.proto_version}', publication_names '#{state.publication_name}')"

      expected_next_state = %{state | step: :streaming}

      assert {:stream, ^expected_stream_query, [], ^expected_next_state} =
               ReplicationConnection.handle_result(result, state)
    end

    test "handle_result creates publication if it doesn't exist" do
      state = %{@mock_state | step: :create_publication}
      result = [%Postgrex.Result{num_rows: 0}]

      expected_tables = "test_schema.accounts,test_schema.resources"
      expected_query = "CREATE PUBLICATION #{state.publication_name} FOR TABLE #{expected_tables}"
      expected_next_state = %{state | step: :check_replication_slot}

      assert {:query, ^expected_query, ^expected_next_state} =
               ReplicationConnection.handle_result(result, state)
    end

    test "handle_result transitions from check_replication_slot to create_replication_slot after creating publication" do
      state = %{@mock_state | step: :check_replication_slot}
      result = [%Postgrex.Result{num_rows: 0}]

      expected_query =
        "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

      expected_next_state = %{state | step: :create_replication_slot}

      assert {:query, ^expected_query, ^expected_next_state} =
               ReplicationConnection.handle_result(result, state)
    end

    test "handle_result creates replication slot if it doesn't exist" do
      state = %{@mock_state | step: :create_replication_slot}
      result = [%Postgrex.Result{num_rows: 0}]

      expected_query =
        "CREATE_REPLICATION_SLOT #{state.replication_slot_name} LOGICAL #{state.output_plugin} NOEXPORT_SNAPSHOT"

      expected_next_state = %{state | step: :start_replication_slot}

      assert {:query, ^expected_query, ^expected_next_state} =
               ReplicationConnection.handle_result(result, state)
    end
  end

  # In-depth decoding tests are handled in Domain.Events.DecoderTest
  describe "handle_data/2" do
    test "handle_data handles KeepAlive with reply :now" do
      state = %{@mock_state | step: :streaming}
      wal_end = 12345

      now =
        System.os_time(:microsecond) - DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)

      # 100 milliseconds
      grace_period = 100_000
      keepalive_data = <<?k, wal_end::64, 0::64, 1>>

      assert {:noreply, reply, ^state} =
               ReplicationConnection.handle_data(keepalive_data, state)

      assert [<<?r, 12346::64, 12346::64, 12346::64, clock::64, 1::8>>] = reply

      assert now <= clock
      assert clock < now + grace_period
    end

    test "handle_data handles KeepAlive with reply :later" do
      state = %{@mock_state | step: :streaming}
      wal_end = 54321

      keepalive_data = <<?k, wal_end::64, 0::64, 0>>
      expected_reply_message = []

      assert {:noreply, ^expected_reply_message, ^state} =
               ReplicationConnection.handle_data(keepalive_data, state)
    end

    test "handle_data handles Write message" do
      state = %{@mock_state | step: :streaming}
      server_wal_start = 123_456_789
      server_wal_end = 987_654_321
      server_system_clock = 1_234_567_890
      message = "Hello, world!"

      write_data =
        <<?w, server_wal_start::64, server_wal_end::64, server_system_clock::64, message::binary>>

      assert {:noreply, [], ^state} = ReplicationConnection.handle_data(write_data, state)
    end

    test "handle_data handles unknown message" do
      state = %{@mock_state | step: :streaming}
      unknown_data = <<?q, 1, 2, 3>>

      assert {:noreply, [], ^state} = ReplicationConnection.handle_data(unknown_data, state)
    end
  end

  describe "handle_info/2" do
    test "handle_info handles :shutdown message" do
      state = @mock_state
      assert {:disconnect, :normal} = ReplicationConnection.handle_info(:shutdown, state)
    end

    test "handle_info handles :DOWN message from monitored process" do
      state = @mock_state
      monitor_ref = make_ref()
      down_msg = {:DOWN, monitor_ref, :process, :some_pid, :shutdown}

      assert {:disconnect, :normal} = ReplicationConnection.handle_info(down_msg, state)
    end

    test "handle_info ignores other messages" do
      state = @mock_state
      random_msg = {:some_other_info, "data"}

      assert {:noreply, ^state} = ReplicationConnection.handle_info(random_msg, state)
    end
  end

  describe "handle_disconnect/1" do
    test "handle_disconnect resets step to :disconnected and logs warning" do
      state = %{@mock_state | step: :streaming}
      expected_state = %{state | step: :disconnected}

      log_output =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, ^expected_state} = ReplicationConnection.handle_disconnect(state)
        end)

      assert log_output =~ "Replication connection disconnected"
    end
  end
end
