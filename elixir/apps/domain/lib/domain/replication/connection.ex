# CREDIT: https://github.com/supabase/realtime/blob/main/lib/realtime/tenants/replication_connection.ex
defmodule Domain.Replication.Connection do
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
          use Domain.Replication.Connection,
            alert_threshold_ms: 30_000,
            publication_name: "my_events"
        end

    ## Options

      * `:alert_threshold_ms` - How long to allow the WAL stream to lag before logging a warning (default: 5000)
      * `:publication_name` - Name of the PostgreSQL publication (default: "events")
  """

  defmacro __using__(opts \\ []) do
    # Compose all the quote blocks without nesting
    [
      basic_setup(),
      struct_and_constants(opts),
      connection_functions(),
      query_handlers(),
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

      import Domain.Replication.Protocol
      import Domain.Replication.Decoder

      alias Domain.Replication.Decoder
      alias Domain.Replication.Protocol.{KeepAlive, Write}
    end
  end

  # Extract struct definition and constants
  defp struct_and_constants(opts) do
    quote bind_quoted: [opts: opts] do
      # Only these two are configurable
      @alert_threshold_ms Keyword.fetch!(opts, :alert_threshold_ms)
      @publication_name Keyword.fetch!(opts, :publication_name)

      # Everything else uses defaults
      @status_log_interval :timer.minutes(5)
      @replication_slot_name "#{@publication_name}_slot"
      @schema "public"
      @output_plugin "pgoutput"
      @proto_version 1

      @type t :: %__MODULE__{
              schema: String.t(),
              step:
                :disconnected
                | :check_publication
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
              counter: integer()
            }

      defstruct schema: @schema,
                step: :disconnected,
                publication_name: @publication_name,
                replication_slot_name: @replication_slot_name,
                output_plugin: @output_plugin,
                proto_version: @proto_version,
                table_subscriptions: [],
                relations: %{},
                counter: 0
    end
  end

  # Extract connection setup functions
  defp connection_functions do
    quote do
      def start_link(%{instance: %__MODULE__{} = instance, connection_opts: connection_opts}) do
        opts = connection_opts ++ [name: {:global, __MODULE__}]
        Postgrex.ReplicationConnection.start_link(__MODULE__, instance, opts)
      end

      @impl true
      def init(state) do
        {:ok, Map.put(state, :lag_threshold_exceeded, false)}
      end

      @doc """
        Called when we make a successful connection to the PostgreSQL server.
      """
      @impl true
      def handle_connect(state) do
        query = "SELECT 1 FROM pg_publication WHERE pubname = '#{state.publication_name}'"
        {:query, query, %{state | step: :create_publication}}
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

  # Extract query result handlers
  defp query_handlers do
    quote do
      @doc """
        Generic callback that handles replies to the queries we send.

        We use a simple state machine to issue queries one at a time to Postgres in order to:

        1. Check if the publication exists
        2. Check if the replication slot exists
        3. Create the publication if it doesn't exist
        4. Create the replication slot if it doesn't exist
        5. Start the replication slot
        6. Start streaming data from the replication slot
      """
      @impl true
      def handle_result(
            [%Postgrex.Result{num_rows: 1}],
            %__MODULE__{step: :create_publication} = state
          ) do
        query =
          "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

        {:query, query, %{state | step: :create_replication_slot}}
      end

      def handle_result(
            [%Postgrex.Result{num_rows: 1}],
            %__MODULE__{step: :create_replication_slot} = state
          ) do
        {:query, "SELECT 1", %{state | step: :start_replication_slot}}
      end

      def handle_result([%Postgrex.Result{}], %__MODULE__{step: :start_replication_slot} = state) do
        Logger.info("Starting replication slot #{state.replication_slot_name}",
          state: inspect(state)
        )

        # Start logging regular status updates
        send(self(), :interval_logger)

        query =
          "START_REPLICATION SLOT \"#{state.replication_slot_name}\" LOGICAL 0/0  (proto_version '#{state.proto_version}', publication_names '#{state.publication_name}')"

        {:stream, query, [], %{state | step: :streaming}}
      end

      def handle_result(
            [%Postgrex.Result{num_rows: 0}],
            %__MODULE__{step: :create_publication} = state
          ) do
        tables =
          state.table_subscriptions
          |> Enum.map_join(",", fn table -> "#{state.schema}.#{table}" end)

        query = "CREATE PUBLICATION #{state.publication_name} FOR TABLE #{tables}"
        {:query, query, %{state | step: :check_replication_slot}}
      end

      def handle_result([%Postgrex.Result{}], %__MODULE__{step: :check_replication_slot} = state) do
        query =
          "SELECT 1 FROM pg_replication_slots WHERE slot_name = '#{state.replication_slot_name}'"

        {:query, query, %{state | step: :create_replication_slot}}
      end

      def handle_result(
            [%Postgrex.Result{num_rows: 0}],
            %__MODULE__{step: :create_replication_slot} = state
          ) do
        query =
          "CREATE_REPLICATION_SLOT #{state.replication_slot_name} LOGICAL #{state.output_plugin} NOEXPORT_SNAPSHOT"

        {:query, query, %{state | step: :start_replication_slot}}
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

        wal_end = wal_end + 1

        message =
          case reply do
            :now -> standby_status(wal_end, wal_end, wal_end, reply)
            :later -> hold()
          end

        {:noreply, message, state}
      end

      def handle_data(data, state) when is_write(data) do
        OpenTelemetry.Tracer.with_span "#{__MODULE__}.handle_data/2" do
          %Write{server_wal_end: server_wal_end, message: message} = parse(data)

          message
          |> decode_message()
          |> handle_message(server_wal_end, %{state | counter: state.counter + 1})
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
      #   1. Insert/Update/Delete/Begin/Commit - send to appropriate hook
      #   2. Relation messages - store the relation data in our state so we can use it later
      #      to associate column names etc with the data we receive. In practice, we'll always
      #      see a Relation message before we see any data for that relation.
      #   3. Origin/Truncate/Type - we ignore these messages for now
      #   4. Graceful shutdown - we respond with {:disconnect, :normal} to
      #      indicate that we are shutting down gracefully and prevent auto reconnecting.
      defp handle_message(
             %Decoder.Messages.Relation{
               id: id,
               namespace: namespace,
               name: name,
               columns: columns
             },
             _server_wal_end,
             state
           ) do
        relation = %{
          namespace: namespace,
          name: name,
          columns: columns
        }

        {:noreply, [], %{state | relations: Map.put(state.relations, id, relation)}}
      end

      defp handle_message(%Decoder.Messages.Insert{} = msg, server_wal_end, state) do
        {op, table, _old_data, data} = transform(msg, state.relations)
        :ok = on_insert(server_wal_end, table, data)
        {:noreply, [], state}
      end

      defp handle_message(%Decoder.Messages.Update{} = msg, server_wal_end, state) do
        {op, table, old_data, data} = transform(msg, state.relations)
        :ok = on_update(server_wal_end, table, old_data, data)
        {:noreply, [], state}
      end

      defp handle_message(%Decoder.Messages.Delete{} = msg, server_wal_end, state) do
        {op, table, old_data, _data} = transform(msg, state.relations)
        :ok = on_delete(server_wal_end, table, old_data)
        {:noreply, [], state}
      end
    end
  end

  # Extract transaction and ignored message handlers
  defp transaction_handlers do
    quote do
      defp handle_message(%Decoder.Messages.Begin{} = msg, server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_message(
             %Decoder.Messages.Commit{commit_timestamp: commit_timestamp} = msg,
             _server_wal_end,
             state
           ) do
        # Since we receive a commit for each operation and we process each operation
        # one-by-one, we can use the commit timestamp to check if we are lagging behind.
        lag_ms = DateTime.diff(commit_timestamp, DateTime.utc_now(), :millisecond)
        send(self(), {:check_alert, lag_ms})

        {:noreply, [], state}
      end
    end
  end

  # Extract handlers for ignored message types
  defp ignored_message_handlers do
    quote do
      # These messages are not relevant for our use case, so we ignore them.
      defp handle_message(%Decoder.Messages.Origin{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_message(%Decoder.Messages.Truncate{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_message(%Decoder.Messages.Type{}, _server_wal_end, state) do
        {:noreply, [], state}
      end

      defp handle_message(%Decoder.Messages.Unsupported{data: data}, _server_wal_end, state) do
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
        |> Map.new(fn {value, column} -> {column.name, value} end)
        |> Enum.into(%{})
      end
    end
  end

  # Extract info handlers
  defp info_handlers(opts) do
    quote bind_quoted: [opts: opts] do
      @alert_threshold_ms Keyword.fetch!(opts, :alert_threshold_ms)
      @status_log_interval :timer.minutes(5)

      @impl true
      # Log only once when crossing the threshold
      def handle_info({:check_alert, lag_ms}, %{lag_threshold_exceeded: false} = state)
          when lag_ms >= @alert_threshold_ms do
        Logger.warning("#{__MODULE__}: Processing lag exceeds threshold", lag_ms: lag_ms)
        {:noreply, %{state | lag_threshold_exceeded: true}}
      end

      def handle_info({:check_alert, lag_ms}, %{lag_threshold_exceeded: true} = state)
          when lag_ms < @alert_threshold_ms do
        Logger.info("#{__MODULE__}: Processing lag is back below threshold", lag_ms: lag_ms)
        {:noreply, %{state | lag_threshold_exceeded: false}}
      end

      def handle_info(:interval_logger, state) do
        Logger.info(
          "#{__MODULE__}: Processed #{state.counter} write messages from the WAL stream"
        )

        Process.send_after(self(), :interval_logger, @status_log_interval)

        {:noreply, state}
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
      def on_insert(_lsn, _table, _data), do: :ok
      def on_update(_lsn, _table, _old_data, _data), do: :ok
      def on_delete(_lsn, _table, _old_data), do: :ok

      defoverridable on_insert: 3, on_update: 4, on_delete: 3
    end
  end
end
