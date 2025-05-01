# CREDIT: https://github.com/supabase/realtime/blob/main/lib/realtime/tenants/replication_connection.ex
defmodule Domain.Events.ReplicationConnection do
  @moduledoc """
    Receives WAL events from PostgreSQL and broadcasts them where they need to go.

    Generally, we only want to start one of these connections per cluster in order
    to obtain a serial stream of the WAL. We can then fanout these events to the
    appropriate consumers.

    The ReplicationConnection is started with a durable slot so that whatever data we
    fail to acknowledge is retained in the slot on the server's disk. The server will
    then send us the data when we reconnect. This is important because we want to
    ensure that we don't lose any WAL data if we disconnect or crash, such as during a deploy.

    The WAL data we receive is sent only once a COMMIT completes on the server. So even though
    COMMIT is one of the message types we receive here, we can safely ignore it and process
    insert/update/delete messages one-by-one in this module as we receive them.
  """
  use Postgrex.ReplicationConnection
  require Logger

  import Domain.Events.Protocol
  import Domain.Events.Decoder

  alias Domain.Events.Event
  alias Domain.Events.Decoder
  alias Domain.Events.Protocol.{KeepAlive, Write}

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
          relations: map()
        }
  defstruct schema: "public",
            step: :disconnected,
            publication_name: "events",
            replication_slot_name: "events_slot",
            output_plugin: "pgoutput",
            proto_version: 1,
            table_subscriptions: [],
            relations: %{}

  def start_link(%{instance: %__MODULE__{} = instance, connection_opts: connection_opts}) do
    # Start only one ReplicationConnection in the cluster.
    opts = connection_opts ++ [name: {:global, __MODULE__}]

    case(Postgrex.ReplicationConnection.start_link(__MODULE__, instance, opts)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      error ->
        Logger.error("Failed to start replication connection!",
          error: inspect(error)
        )

        error
    end
  end

  @impl true
  def init(state) do
    {:ok, state}
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
    Logger.info("Starting replication slot", state: inspect(state))

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
    %Write{message: message} = parse(data)

    # TODO: Telemetry: Mark start
    message
    |> decode_message()
    |> handle_message(state)
  end

  def handle_data(data, state) do
    Logger.error("Unknown WAL message received!",
      data: inspect(data),
      state: inspect(state)
    )

    {:noreply, [], state}
  end

  # Handles messages received:
  #
  #   1. Insert/Update/Delete - send to Event.ingest/2 for further processing
  #   2. Relation messages - store the relation data in our state so we can use it later
  #      to associate column names etc with the data we receive. In practice, we'll always
  #      see a Relation message before we see any data for that relation.
  #   3. Begin/Commit/Origin/Truncate/Type - we ignore these messages for now
  #   4. Graceful shutdown - we respond with {:disconnect, :normal} to
  #      indicate that we are shutting down gracefully and prevent auto reconnecting.
  defp handle_message(
         %Decoder.Messages.Relation{
           id: id,
           namespace: namespace,
           name: name,
           columns: columns
         },
         state
       ) do
    relation = %{
      namespace: namespace,
      name: name,
      columns: columns
    }

    {:noreply, [], %{state | relations: Map.put(state.relations, id, relation)}}
  end

  defp handle_message(%Decoder.Messages.Insert{} = msg, state) do
    :ok = Event.ingest(msg, state.relations)
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Update{} = msg, state) do
    :ok = Event.ingest(msg, state.relations)
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Delete{} = msg, state) do
    :ok = Event.ingest(msg, state.relations)
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Begin{}, state) do
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Commit{}, state) do
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Origin{}, state) do
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Truncate{}, state) do
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Type{}, state) do
    {:noreply, [], state}
  end

  defp handle_message(%Decoder.Messages.Unsupported{data: data}, state) do
    Logger.warning("Unsupported message received",
      data: inspect(data),
      state: inspect(state)
    )

    {:noreply, [], state}
  end

  @impl true

  def handle_info(:shutdown, _), do: {:disconnect, :normal}
  def handle_info({:DOWN, _, :process, _, _}, _), do: {:disconnect, :normal}

  def handle_info(_, state), do: {:noreply, state}

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
    Logger.info("Replication connection disconnected",
      state: inspect(state)
    )

    {:noreply, %{state | step: :disconnected}}
  end
end
