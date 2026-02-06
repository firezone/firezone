# CREDIT: https://github.com/supabase/realtime/blob/main/lib/realtime/tenants/replication_connection.ex
defmodule Portal.Replication.Connection do
  @moduledoc """
    Receives WAL events from PostgreSQL and broadcasts them where they need to go.

    The ReplicationConnection is started with a durable slot so that whatever data we
    fail to acknowledge is retained in the slot on the server's disk. The server will
    then send us the data when we reconnect. This is important because we want to
    ensure that we don't lose any WAL data if we disconnect or crash, such as during a deploy.

    The WAL data we receive is sent only once a COMMIT completes on the server. So even though
    COMMIT is one of the message types we receive here, we can safely ignore it and process
    insert/update/delete messages one-by-one in this module as we receive them.

    ## Usage

        defmodule MyApp.ReplicationConnection do
          use Portal.Replication.Connection
        end
  """

  defmacro __using__(opts \\ []) do
    # Compose all the quote blocks without nesting
    [
      basic_setup(),
      struct_and_constants(opts),
      connection_functions(),
      publication_handlers(),
      replication_slot_handlers(),
      query_helper_functions(),
      data_handlers(),
      message_handlers(),
      transaction_handlers(),
      ignored_message_handlers(),
      utility_functions(),
      info_handlers(opts),
      default_callbacks()
    ]
  end

  # Extract basic imports and aliases
  defp basic_setup do
    quote do
      use Postgrex.ReplicationConnection
      require Logger
      require OpenTelemetry.Tracer

      import Portal.Replication.Protocol
      import Portal.Replication.Decoder

      alias Portal.Replication.Decoder
      alias Portal.Replication.Protocol.{KeepAlive, Write}
    end
  end

  # Extract struct definition and constants
  defp struct_and_constants(opts) do
    quote bind_quoted: [opts: opts] do
      # Everything else uses defaults
      @schema "public"
      @output_plugin "pgoutput"
      @proto_version 1

      @type t :: %__MODULE__{
              schema: String.t(),
              step:
                :disconnected
                | :check_publication
                | :check_publication_tables
                | :remove_publication_tables
                | :create_publication
                | :check_replication_slot
                | :create_slot
                | :start_replication_slot
                | :streaming,
              publication_name: String.t(),
              replication_slot_name: String.t(),
              output_plugin: String.t(),
              proto_version: integer(),
              table_subscriptions: list(),
              relations: map(),
              counter: integer(),
              tables_to_remove: MapSet.t(),
              flush_interval: integer(),
              flush_buffer: map(),
              last_flushed_lsn: integer(),
              warning_threshold_exceeded?: boolean(),
              error_threshold_exceeded?: boolean(),
              flush_buffer_size: integer(),
              status_log_interval: integer(),
              warning_threshold: integer(),
              error_threshold: integer(),
              last_sent_lsn: integer() | nil,
              last_keep_alive: DateTime.t() | nil,
              region: String.t()
            }

      defstruct(
        # schema to use for the publication
        schema: @schema,
        # starting step
        step: :disconnected,
        # publication name to check/create
        publication_name: nil,
        # replication slot name to check/create
        replication_slot_name: nil,
        # output plugin to use for logical replication
        output_plugin: @output_plugin,
        # protocol version to use for logical replication
        proto_version: @proto_version,
        # tables we want to subscribe to in the publication
        table_subscriptions: [],
        # relations we have seen so far
        relations: %{},
        # counter for the number of messages processed
        counter: 0,
        # calculated tables to remove from the publication
        tables_to_remove: MapSet.new(),
        # flush interval in milliseconds, set to 0 to use immediate processing
        flush_interval: 0,
        # buffer for data to flush
        flush_buffer: %{},
        # last flushed LSN, used to track progress while flushing
        last_flushed_lsn: 0,
        # flags to track if we have exceeded warning/error thresholds
        warning_threshold_exceeded?: false,
        error_threshold_exceeded?: false,
        # size of the flush buffer, used to determine when to flush
        flush_buffer_size: 0,
        # interval for logging status updates
        status_log_interval: :timer.minutes(1),
        # thresholds for warning and error logging
        warning_threshold: :timer.seconds(30),
        error_threshold: :timer.seconds(60),
        # last sent LSN, used to log acknowledgement progress
        last_sent_lsn: nil,
        # last keep alive message received at
        last_keep_alive: nil,
        # region for scoping :pg leader election
        region: "default"
      )
    end
  end

  # Extract connection setup functions
  defp connection_functions do
    quote do
      def start_link(%{instance: %__MODULE__{} = instance, connection_opts: connection_opts}) do
        Postgrex.ReplicationConnection.start_link(__MODULE__, instance, connection_opts)
      end

      @impl true
      def init(state) do
        # Join pg group so other nodes can discover and link to us.
        # Scoped by region so each region elects its own leader.
        :ok = :pg.join({__MODULE__, state.region}, self())

        if state.flush_interval > 0 do
          Process.send_after(self(), :flush, state.flush_interval)
        end

        {:ok, state}
      end

      @doc """
        Called when we make a successful connection to the PostgreSQL server.
      """
      @impl true
      def handle_connect(state) do
        query = "SELECT 1 FROM pg_publication WHERE pubname = '#{state.publication_name}'"
        {:query, query, %{state | step: :check_publication}}
      end

      @doc """
        Called when the connection is disconnected unexpectedly.

        This will happen if:
          1. Postgres is restarted such as during a maintenance window
          2. The connection is closed by the server due to our failure to acknowledge
             Keepalive messages in a timely manner
          3. The connection is cut due to a network error
          4. The ReplicationConnection process crashes or is killed abruptly for any reason
          5. Potentially during a deploy if the connection is not closed gracefully.

        Our Supervisor will restart this process automatically so this is not an error.
      """
      @impl true
      def handle_disconnect(state) do
        Logger.info("#{__MODULE__}: Replication connection disconnected",
          counter: state.counter
        )

        {:noreply, %{state | step: :disconnected}}
      end
    end
  end

  # Handle publication-related queries
  defp publication_handlers do
    quote do
      @doc """
        Generic callback that handles replies to the queries we send.

        We use a simple state machine to issue queries one at a time to Postgres in order to:

        1. Check if the publication exists
        2. If it exists, check what tables are currently in the publication
        3. Diff the desired vs current tables and update the publication as needed
        4. If it doesn't exist, create the publication with the desired tables
        5. Check if the replication slot exists
        6. Create the replication slot if it doesn't exist
        7. Start the replication slot
        8. Start streaming data from the replication slot
      """
      @impl true
      def handle_result(
            [%Postgrex.Result{num_rows: 1}],
            %__MODULE__{step: :check_publication} = state
          ) do
        # Publication exists, check what tables are in it
        query = """
        SELECT schemaname, tablename
        FROM pg_publication_tables
        WHERE pubname = '#{state.publication_name}'
        ORDER BY schemaname, tablename
        """

        {:query, query, %{state | step: :check_publication_tables}}
      end

      def handle_result(
            [%Postgrex.Result{rows: existing_table_rows}],
            %__MODULE__{step: :check_publication_tables} = state
          ) do
        handle_publication_tables_diff(existing_table_rows, state)
      end

      def handle_result(
            [%Postgrex.Result{}],
            %__MODULE__{step: :remove_publication_tables, tables_to_remove: to_remove} = state
          ) do
        handle_remove_publication_tables(to_remove, state)
      end

      def handle_result(
            [%Postgrex.Result{num_rows: 0}],
            %__MODULE__{step: :check_publication} = state
          ) do
        # Publication doesn't exist, create it with all desired tables
        tables =
          state.table_subscriptions
          |> Enum.map_join(",", fn table -> "#{state.schema}.#{table}" end)

        Logger.info(
          "#{__MODULE__}: Creating publication #{state.publication_name} with tables: #{tables}"
        )

        query = "CREATE PUBLICATION #{state.publication_name} FOR TABLE #{tables}"
        {:query, query, %{state | step: :check_replication_slot}}
      end

      def handle_result([%Postgrex.Result{}], %__MODULE__{step: :create_publication} = state) do
        query =
          "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

        {:query, query, %{state | step: :create_slot}}
      end
    end
  end

  # Handle replication slot-related queries
  defp replication_slot_handlers do
    quote do
      def handle_result([%Postgrex.Result{}], %__MODULE__{step: :check_replication_slot} = state) do
        query =
          "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

        {:query, query, %{state | step: :create_slot}}
      end

      def handle_result(
            [%Postgrex.Result{num_rows: 1}],
            %__MODULE__{step: :create_slot} = state
          ) do
        {:query, "SELECT 1", %{state | step: :start_replication_slot}}
      end

      def handle_result([%Postgrex.Result{}], %__MODULE__{step: :start_replication_slot} = state) do
        Logger.info("#{__MODULE__}: Starting replication slot #{state.replication_slot_name}",
          state: inspect(state)
        )

        # Start logging regular status updates
        send(self(), :interval_logger)

        query =
          "START_REPLICATION SLOT \"#{state.replication_slot_name}\" LOGICAL 0/0  (proto_version '#{state.proto_version}', publication_names '#{state.publication_name}', messages 'true')"

        {:stream, query, [], %{state | step: :streaming}}
      end

      def handle_result(
            [%Postgrex.Result{num_rows: 0}],
            %__MODULE__{step: :create_slot} = state
          ) do
        query =
          "CREATE_REPLICATION_SLOT #{state.replication_slot_name} LOGICAL #{state.output_plugin} NOEXPORT_SNAPSHOT"

        {:query, query, %{state | step: :start_replication_slot}}
      end
    end
  end

  # Helper functions for query handling
  defp query_helper_functions do
    quote do
      # Helper function to handle publication table diffing
      defp handle_publication_tables_diff(existing_table_rows, state) do
        # Convert existing tables to the same format as our desired tables
        current_tables =
          existing_table_rows
          |> Enum.map(fn [schema, table] -> "#{schema}.#{table}" end)
          |> MapSet.new()

        desired_tables =
          state.table_subscriptions
          |> Enum.map(fn table -> "#{state.schema}.#{table}" end)
          |> MapSet.new()

        to_add = MapSet.difference(desired_tables, current_tables)
        to_remove = MapSet.difference(current_tables, desired_tables)

        cond do
          not Enum.empty?(to_add) ->
            tables = Enum.join(to_add, ", ")
            Logger.info("#{__MODULE__}: Adding tables to publication: #{tables}")

            {:query, "ALTER PUBLICATION #{state.publication_name} ADD TABLE #{tables}",
             %{state | step: :remove_publication_tables, tables_to_remove: to_remove}}

          not Enum.empty?(to_remove) ->
            tables = Enum.join(to_remove, ", ")
            Logger.info("#{__MODULE__}: Removing tables from publication: #{tables}")

            {:query, "ALTER PUBLICATION #{state.publication_name} DROP TABLE #{tables}",
             %{state | step: :check_replication_slot}}

          true ->
            # No changes needed
            Logger.info("#{__MODULE__}: Publication tables are up to date")

            query =
              "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

            {:query, query, %{state | step: :create_slot}}
        end
      end

      # Helper function to handle removing remaining tables
      defp handle_remove_publication_tables(to_remove, state) do
        if Enum.empty?(to_remove) do
          # No tables to remove, proceed to replication slot
          query =
            "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

          {:query, query, %{state | step: :create_slot}}
        else
          # Remove the remaining tables
          tables = Enum.join(to_remove, ", ")
          Logger.info("#{__MODULE__}: Removing tables from publication: #{tables}")

          {:query, "ALTER PUBLICATION #{state.publication_name} DROP TABLE #{tables}",
           %{state | step: :check_replication_slot}}
        end
      end
    end
  end

  # Extract data handling functions
  defp data_handlers do
    quote do
      @doc """
        Called when we receive a message from the PostgreSQL server.

        We handle the following messages:
          1. KeepAlive: A message sent by PostgreSQL to keep the connection alive and also acknowledge
             processed data by responding with the current WAL position.
          2. Write: A message containing a WAL event - the actual data we are interested in.
          3. Unknown: Any other message that we don't know how to handle - we log and ignore it.

        For the KeepAlive message, we respond immediately with the current WAL position. Note: it is expected
        that we receive many more of these messages than expected. That is because the rate at which the server
        sends these messages scales proportionally to the number of Write messages it sends.

        For the Write message, we send broadcast for each message one-by-one as we receive it. This is important
        because the WAL stream from Postgres is ordered; if we reply to a Keepalive advancing the WAL position,
        we should have already processed all the messages up to that point.
      """
      @impl true
      def handle_data(data, state) when is_keep_alive(data) do
        %KeepAlive{reply: reply, wal_end: wal_end} = parse(data)

        # PostgreSQL standby_status takes three positions:
        #   - write: last WAL byte + 1 RECEIVED (may not be persisted yet)
        #   - flush: last WAL byte + 1 DURABLY STORED (flushed to disk)
        #   - apply: last WAL byte + 1 APPLIED/PROCESSED
        #
        # For buffered mode, we need to distinguish between what we've received vs flushed:
        #   - write = wal_end + 1 (tells PostgreSQL we're receiving data, prevents rapid KeepAlives)
        #   - flush/apply = last_flushed_lsn + 1 (tells PostgreSQL what's safe to remove from slot)
        #
        # This allows PostgreSQL to know we're alive and receiving data (write), while also
        # preserving durability by tracking what we've actually persisted (flush/apply).

        {write_lsn, flush_lsn} =
          if state.flush_interval == 0 do
            # Not buffering - we process immediately, all positions are current
            lsn = wal_end + 1
            {lsn, lsn}
          else
            # Buffering mode - we've received up to wal_end, but only flushed up to last_flushed_lsn
            write = wal_end + 1

            flush =
              if state.last_flushed_lsn > 0 do
                state.last_flushed_lsn + 1
              else
                # Haven't flushed anything yet - use write position to avoid tight loop
                # This trades some durability for stability during initial buffering
                write
              end

            {write, flush}
          end

        # Always reply with standby status to send acks. When wal_sender_timeout is disabled,
        # we won't always receive KeepAlive messages with the reply field set.
        message = standby_status(write_lsn, flush_lsn, flush_lsn, reply)

        state = %{state | last_sent_lsn: flush_lsn, last_keep_alive: DateTime.utc_now()}

        {:noreply, message, state}
      end

      def handle_data(data, state) when is_write(data) do
        OpenTelemetry.Tracer.with_span "#{__MODULE__}.handle_data/2" do
          %Write{server_wal_end: server_wal_end, message: message} = parse(data)

          message
          |> decode_message()
          |> handle_write(server_wal_end, %{state | counter: state.counter + 1})
        end
      end

      def handle_data(data, state) do
        Logger.error("#{__MODULE__}: Unknown WAL message received!",
          data: inspect(data),
          state: inspect(state)
        )

        {:noreply, [], state}
      end
    end
  end

  # Extract core message handling functions
  defp message_handlers do
    quote do
      # Handles messages received:
      #
      #   1. Insert/Update/Delete - send to on_write/5
      #   2. Begin - check how far we are lagging behind
      #   3. Relation messages - store the relation data in our state so we can use it later
      #      to associate column names etc with the data we receive. In practice, we'll always
      #      see a Relation message before we see any data for that relation.
      #   4. Origin/Truncate/Type - we ignore these messages for now
      #   5. Graceful shutdown - we respond with {:disconnect, :normal} to
      #      indicate that we are shutting down gracefully and prevent auto reconnecting.
      defp handle_write(
             %Decoder.Messages.Relation{
               id: id,
               namespace: namespace,
               name: name,
               columns: columns
             },
             server_wal_end,
             state
           ) do
        relation = %{
          namespace: namespace,
          name: name,
          columns: columns
        }

        {:noreply, [], %{state | relations: Map.put(state.relations, id, relation)}}
      end

      defp handle_write(%Decoder.Messages.Insert{} = msg, server_wal_end, state) do
        process_write(msg, server_wal_end, state)
      end

      defp handle_write(%Decoder.Messages.Update{} = msg, server_wal_end, state) do
        process_write(msg, server_wal_end, state)
      end

      defp handle_write(%Decoder.Messages.Delete{} = msg, server_wal_end, state) do
        process_write(msg, server_wal_end, state)
      end

      defp process_write(_msg, _server_wal_end, %{error_threshold_exceeded?: true} = state) do
        {:noreply, [], state}
      end

      defp process_write(msg, server_wal_end, state) do
        {op, table, old_data, data} = transform(msg, state.relations)

        state
        |> on_write(server_wal_end, op, table, old_data, data)
        |> maybe_flush()
        |> then(&{:noreply, [], &1})
      end

      defp maybe_flush(%{flush_buffer: buffer, flush_buffer_size: size} = state)
           when map_size(buffer) >= size do
        on_flush(state)
      end

      defp maybe_flush(state), do: state
    end
  end

  # Extract transaction and ignored message handlers
  defp transaction_handlers do
    quote do
      defp handle_write(
             %Decoder.Messages.Begin{commit_timestamp: commit_timestamp} = msg,
             server_wal_end,
             state
           ) do
        # We can use the commit timestamp to check how far we are lagging behind
        lag_ms = DateTime.diff(DateTime.utc_now(), commit_timestamp, :millisecond)
        send(self(), {:check_warning_threshold, lag_ms})
        send(self(), {:check_error_threshold, lag_ms})
        state = on_begin(state, msg)
        {:noreply, [], state}
      end
    end
  end

  # Extract handlers for ignored message types
  defp ignored_message_handlers do
    quote do
      # These messages are not relevant for our use case, so we ignore them.

      defp handle_write(%Decoder.Messages.Commit{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_write(%Decoder.Messages.Origin{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_write(%Decoder.Messages.Truncate{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_write(%Decoder.Messages.Type{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_write(%Decoder.Messages.LogicalMessage{} = msg, _server_wal_end, state) do
        state = on_logical_message(state, msg)
        {:noreply, [], state}
      end

      defp handle_write(%Decoder.Messages.Unsupported{data: data}, _server_wal_end, state) do
        Logger.warning("#{__MODULE__}: Unsupported message received",
          data: inspect(data),
          counter: state.counter
        )

        {:noreply, [], state}
      end
    end
  end

  # Extract data transformation utilities
  defp utility_functions do
    quote do
      defp transform(msg, relations) do
        {op, old_tuple_data, tuple_data} = extract_msg_data(msg)
        {:ok, relation} = Map.fetch(relations, msg.relation_id)
        table = relation.name
        old_data = zip(old_tuple_data, relation.columns)
        data = zip(tuple_data, relation.columns)

        {
          op,
          table,
          old_data,
          data
        }
      end

      defp extract_msg_data(%Decoder.Messages.Insert{tuple_data: data}) do
        {:insert, nil, data}
      end

      defp extract_msg_data(%Decoder.Messages.Update{old_tuple_data: old, tuple_data: data}) do
        {:update, old, data}
      end

      defp extract_msg_data(%Decoder.Messages.Delete{old_tuple_data: old}) do
        {:delete, old, nil}
      end

      defp zip(nil, _), do: nil

      defp zip(tuple_data, columns) do
        tuple_data
        |> Tuple.to_list()
        |> Enum.zip(columns)
        |> Map.new(&Decoder.decode_json/1)
      end
    end
  end

  defp info_handlers(opts) do
    quote bind_quoted: [opts: opts] do
      @impl true

      def handle_info(
            {:check_warning_threshold, lag_ms},
            %{warning_threshold_exceeded?: false, warning_threshold: warning_threshold} = state
          )
          when lag_ms >= warning_threshold do
        Logger.warning("#{__MODULE__}: Processing lag exceeds warning threshold", lag_ms: lag_ms)
        {:noreply, %{state | warning_threshold_exceeded?: true}}
      end

      def handle_info(
            {:check_warning_threshold, lag_ms},
            %{warning_threshold_exceeded?: true, warning_threshold: warning_threshold} = state
          )
          when lag_ms < warning_threshold do
        Logger.info("#{__MODULE__}: Processing lag is back below warning threshold",
          lag_ms: lag_ms
        )

        {:noreply, %{state | warning_threshold_exceeded?: false}}
      end

      def handle_info(
            {:check_error_threshold, lag_ms},
            %{error_threshold_exceeded?: false, error_threshold: error_threshold} = state
          )
          when lag_ms >= error_threshold do
        Logger.error(
          "#{__MODULE__}: Processing lag exceeds error threshold; skipping side effects!",
          lag_ms: lag_ms
        )

        {:noreply, %{state | error_threshold_exceeded?: true}}
      end

      def handle_info(
            {:check_error_threshold, lag_ms},
            %{error_threshold_exceeded?: true, error_threshold: error_threshold} = state
          )
          when lag_ms < error_threshold do
        Logger.info("#{__MODULE__}: Processing lag is back below error threshold", lag_ms: lag_ms)
        {:noreply, %{state | error_threshold_exceeded?: false}}
      end

      def handle_info(:interval_logger, state) do
        Logger.info(
          "#{__MODULE__}: Processed #{state.counter} write messages from the WAL stream",
          last_sent_lsn: state.last_sent_lsn,
          last_keep_alive: state.last_keep_alive
        )

        Process.send_after(self(), :interval_logger, state.status_log_interval)

        {:noreply, state}
      end

      def handle_info(:flush, state) do
        Process.send_after(self(), :flush, state.flush_interval)

        {:noreply, on_flush(state)}
      end

      def handle_info(:shutdown, _), do: {:disconnect, :normal}
      def handle_info({:DOWN, _, :process, _, _}, _), do: {:disconnect, :normal}

      def handle_info(_, state), do: {:noreply, state}
    end
  end

  # Extract default callback implementations
  defp default_callbacks do
    quote do
      # Default implementations for required callbacks - modules using this should implement these
      def on_write(state, _lsn, _op, _table, _old_data, _data), do: state
      def on_flush(state), do: state
      def on_begin(state, _begin_msg), do: state
      def on_logical_message(state, _message), do: state

      defoverridable on_write: 6, on_flush: 1, on_begin: 2, on_logical_message: 2
    end
  end
end
