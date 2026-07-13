defmodule Portal.Splunk.Sync do
  @moduledoc """
  Delivers log entries to a Splunk HEC endpoint for one log sink.

  Each enabled stream is paged by a `Portal.LogSinkCursor` over the stream's
  `seq` column; the cursor only advances after Splunk acknowledges the batch,
  so delivery is at-least-once. Cursors are seeded lazily on the first run:
  the `:live` cursor starts at the stream's current max seq, and a retroactive
  sink additionally gets a `:backfill` cursor covering everything before that.

  Errors follow the directory sync convention: a 4xx from Splunk disables the
  sink immediately, transient failures (429/5xx/transport) disable it only
  after 24 hours of continuous failure.
  """
  use Oban.Worker,
    queue: :splunk_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.Splunk
  alias __MODULE__.Database

  require Logger

  @batch_size 500
  # Bounds one run; the next scheduler tick resumes from the cursor.
  @max_batches_per_stream 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Database.get_sink(log_sink_id) do
      nil ->
        Logger.info("Splunk log sink not found, disabled, or account disabled, skipping",
          splunk_log_sink_id: log_sink_id
        )

      sink ->
        sync(sink)
    end

    :ok
  end

  def perform(_), do: :ok

  # Rows younger than this are not delivered yet: a row whose seq was assigned
  # in an uncommitted transaction could otherwise be leapfrogged by the cursor.
  # Close-updated flow rows keep their original inserted_at, so for them this
  # guard does not apply and a sub-second race remains; acceptable for now.
  defp visibility_lag_seconds do
    Application.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:visibility_lag_seconds, 30)
  end

  # Splunk Cloud rejects HEC requests larger than ~1 MB with a 413, so chunks
  # stay well under that.
  defp max_body_bytes do
    Application.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:max_body_bytes, 512_000)
  end

  defp sync(sink) do
    Database.seed_missing_cursors(sink)

    result =
      Enum.reduce_while(Database.list_cursors(sink), :ok, fn cursor, :ok ->
        case sync_cursor(sink, cursor, @max_batches_per_stream) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok -> handle_success(sink)
      {:error, reason} -> handle_error(sink, reason)
    end
  end

  defp sync_cursor(_sink, _cursor, 0), do: :ok

  defp sync_cursor(sink, cursor, budget) do
    case Database.next_batch(cursor, @batch_size, visibility_lag_seconds()) do
      [] ->
        Database.maybe_complete_backfill(cursor)
        :ok

      rows ->
        deliver_batch(sink, cursor, rows, budget)
    end
  end

  defp deliver_batch(sink, cursor, rows, budget) do
    encoded =
      Enum.map(rows, fn row ->
        {row.seq, JSON.encode!(hec_event(sink, cursor.stream, row))}
      end)

    case deliver_chunks(sink, cursor, chunk_by_bytes(encoded, max_body_bytes())) do
      {:ok, cursor} -> sync_cursor(sink, cursor, budget - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_chunks(_sink, cursor, []), do: {:ok, cursor}

  defp deliver_chunks(sink, cursor, [chunk | rest]) do
    case deliver_chunk(sink, cursor, chunk) do
      {:ok, cursor} -> deliver_chunks(sink, cursor, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_chunk(sink, cursor, chunk) do
    body = Enum.map_join(chunk, "\n", fn {_seq, json} -> json end)
    max_seq = chunk |> Enum.map(fn {seq, _json} -> seq end) |> Enum.max()

    case Splunk.APIClient.post_events(sink, body) do
      {:ok, %Req.Response{status: 200}} ->
        advance(cursor, max_seq, length(chunk), 0)

      {:ok, %Req.Response{status: 413}} ->
        handle_oversized_chunk(sink, cursor, chunk)

      {:ok, %Req.Response{} = response} ->
        {:error, {:status, response}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # A single event the server still rejects can never be delivered: count it
  # as dropped and move the cursor past it. A rejected multi-event chunk is
  # bisected until the offender is isolated.
  defp handle_oversized_chunk(_sink, cursor, [{seq, _json}]) do
    Logger.warning("Dropping oversized log sink event",
      log_sink_id: cursor.log_sink_id,
      stream: cursor.stream,
      seq: seq
    )

    advance(cursor, seq, 0, 1)
  end

  defp handle_oversized_chunk(sink, cursor, chunk) do
    {left, right} = Enum.split(chunk, div(length(chunk), 2))

    with {:ok, cursor} <- deliver_chunk(sink, cursor, left) do
      deliver_chunk(sink, cursor, right)
    end
  end

  defp advance(cursor, new_seq, delivered, dropped) do
    case Database.advance_cursor(cursor, new_seq, delivered, dropped) do
      {:ok, cursor} -> {:ok, cursor}
      :error -> {:error, :cursor_conflict}
    end
  end

  defp chunk_by_bytes(encoded, max_bytes) do
    Enum.chunk_while(
      encoded,
      {[], 0},
      fn {_seq, json} = item, {acc, bytes} ->
        size = byte_size(json) + 1

        cond do
          acc == [] -> {:cont, {[item], size}}
          bytes + size > max_bytes -> {:cont, Enum.reverse(acc), {[item], size}}
          true -> {:cont, {[item | acc], bytes + size}}
        end
      end,
      fn
        {[], _bytes} -> {:cont, []}
        {acc, _bytes} -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp handle_success(sink) do
    Database.update_sink(sink, %{
      "is_verified" => true,
      "error_message" => nil,
      "errored_at" => nil,
      "is_disabled" => false,
      "disabled_reason" => nil
    })
  end

  defp handle_error(sink, reason) do
    now = DateTime.utc_now()
    message = format_error(reason)

    Logger.warning("Splunk log sink sync failed",
      splunk_log_sink_id: sink.id,
      account_id: sink.account_id,
      reason: message
    )

    case classify(reason) do
      :client_error ->
        Database.update_sink(sink, %{
          "errored_at" => now,
          "error_message" => message,
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })

      :transient ->
        errored_at = sink.errored_at || now
        updates = %{"errored_at" => errored_at, "error_message" => message}

        updates =
          if DateTime.diff(now, errored_at, :hour) >= 24 do
            Map.merge(updates, %{
              "is_disabled" => true,
              "disabled_reason" => "Sync error",
              "is_verified" => false
            })
          else
            updates
          end

        Database.update_sink(sink, updates)
    end
  end

  defp classify({:status, %Req.Response{status: status}})
       when status in [408, 429] or status >= 500 do
    :transient
  end

  defp classify({:status, _response}), do: :client_error
  defp classify({:transport, _exception}), do: :transient
  defp classify(:cursor_conflict), do: :transient

  defp format_error({:status, %Req.Response{status: status, body: body}}) do
    case body do
      %{"text" => text} -> "Splunk HEC returned HTTP #{status}: #{text}"
      _ -> "Splunk HEC returned HTTP #{status}"
    end
  end

  defp format_error({:transport, exception}) do
    Portal.DirectorySync.ErrorHandler.format_transport_error(exception)
  end

  defp format_error(:cursor_conflict), do: "Concurrent sync detected."

  defp hec_event(sink, stream, row) do
    {time, event} = render(stream, row)

    envelope = %{
      "time" => time,
      "source" => "firezone",
      "sourcetype" => "firezone:#{stream}",
      "event" => event
    }

    if sink.index do
      Map.put(envelope, "index", sink.index)
    else
      envelope
    end
  end

  defp render(:change, log) do
    {epoch(log.timestamp),
     %{
       type: "change",
       log_id: log.log_id,
       timestamp: log.timestamp,
       object: log.object,
       operation: log.operation,
       before: log.before,
       after: log.after,
       subject: log.subject
     }}
  end

  defp render(:session, log) do
    {epoch(log.timestamp),
     %{
       type: "session",
       log_id: log.log_id,
       timestamp: log.timestamp,
       context: log.context,
       subject: log.subject
     }}
  end

  defp render(:api_request, log) do
    {epoch(log.inserted_at),
     %{
       type: "api_request",
       log_id: log.log_id,
       timestamp: log.inserted_at,
       actor_id: log.actor_id,
       api_token_id: log.api_token_id,
       method: log.method,
       path: log.path,
       content_length: log.content_length,
       request_id: log.request_id,
       user_agent: log.user_agent,
       ip: log.ip,
       ip_region: log.ip_region,
       ip_city: log.ip_city
     }}
  end

  defp render(:flow, log) do
    phase =
      if is_nil(log.flow_end) do
        "start"
      else
        "end"
      end

    {epoch(log.flow_end || log.flow_start),
     %{
       type: "flow",
       log_id: log.log_id,
       phase: phase,
       flow_start: log.flow_start,
       flow_end: log.flow_end,
       last_packet: log.last_packet,
       device_id: log.device_id,
       role: log.role,
       policy_authorization_id: log.policy_authorization_id,
       policy_id: log.policy_id,
       resource_id: log.resource_id,
       resource_name: log.resource_name,
       resource_address: log.resource_address,
       actor_id: log.actor_id,
       actor_email: log.actor_email,
       actor_name: log.actor_name,
       client_version: log.client_version,
       device_os_name: log.device_os_name,
       device_os_version: log.device_os_version,
       protocol: log.protocol,
       inner_src_ip: log.inner_src_ip,
       inner_src_port: log.inner_src_port,
       inner_dst_ip: log.inner_dst_ip,
       inner_dst_port: log.inner_dst_port,
       outer_src_ip: log.outer_src_ip,
       outer_src_port: log.outer_src_port,
       outer_dst_ip: log.outer_dst_ip,
       outer_dst_port: log.outer_dst_port,
       domain: log.domain,
       rx_packets: log.rx_packets,
       tx_packets: log.tx_packets,
       rx_bytes: log.rx_bytes,
       tx_bytes: log.tx_bytes
     }}
  end

  defp epoch(datetime) do
    DateTime.to_unix(datetime, :millisecond) / 1000
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.LogSinkCursor
    alias Portal.Safe
    alias Portal.Splunk

    @stream_sources %{
      change: {Portal.ChangeLog, :timestamp},
      session: {Portal.SessionLog, :timestamp},
      api_request: {Portal.APIRequestLog, :inserted_at},
      flow: {Portal.FlowLog, :inserted_at}
    }

    def get_sink(id) do
      from(s in Splunk.LogSink,
        join: a in Portal.Account,
        on: a.id == s.account_id,
        where: s.id == ^id,
        where: s.is_disabled == false,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def seed_missing_cursors(sink) do
      existing =
        from(c in LogSinkCursor,
          where: c.account_id == ^sink.account_id,
          where: c.log_sink_id == ^sink.id,
          select: c.stream
        )
        |> Safe.unscoped()
        |> Safe.all()

      rows =
        (sink.enabled_streams -- existing)
        |> Enum.flat_map(&cursor_rows(sink, &1))

      if rows != [] do
        Safe.unscoped()
        |> Safe.insert_all(LogSinkCursor, rows, on_conflict: :nothing)
      end

      :ok
    end

    def list_cursors(sink) do
      from(c in LogSinkCursor,
        where: c.account_id == ^sink.account_id,
        where: c.log_sink_id == ^sink.id,
        where: c.stream in ^sink.enabled_streams,
        where: is_nil(c.completed_at)
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def next_batch(cursor, limit, lag_seconds) do
      {schema, guard_column} = Map.fetch!(@stream_sources, cursor.stream)
      guard_cutoff = DateTime.add(DateTime.utc_now(), -lag_seconds, :second)

      query =
        from(l in schema,
          where: l.account_id == ^cursor.account_id,
          where: l.seq > ^cursor.cursor,
          where: field(l, ^guard_column) < ^guard_cutoff,
          order_by: [asc: l.seq],
          limit: ^limit
        )

      query =
        if cursor.until_seq do
          where(query, [l], l.seq <= ^cursor.until_seq)
        else
          query
        end

      query
      |> Safe.unscoped()
      |> Safe.all()
    end

    def advance_cursor(cursor, new_seq, delivered, dropped) do
      now = DateTime.utc_now()

      {updated, _} =
        from(c in LogSinkCursor,
          where: c.account_id == ^cursor.account_id,
          where: c.log_sink_id == ^cursor.log_sink_id,
          where: c.stream == ^cursor.stream,
          where: c.phase == ^cursor.phase,
          where: c.cursor == ^cursor.cursor
        )
        |> Safe.unscoped()
        |> Safe.update_all(
          set: [cursor: new_seq, last_synced_at: now, updated_at: now],
          inc: [synced_count: delivered, dropped_count: dropped]
        )

      if updated == 1 do
        {:ok,
         %{
           cursor
           | cursor: new_seq,
             synced_count: cursor.synced_count + delivered,
             dropped_count: cursor.dropped_count + dropped
         }}
      else
        :error
      end
    end

    def maybe_complete_backfill(%LogSinkCursor{phase: :backfill, completed_at: nil} = cursor) do
      now = DateTime.utc_now()

      from(c in LogSinkCursor,
        where: c.account_id == ^cursor.account_id,
        where: c.log_sink_id == ^cursor.log_sink_id,
        where: c.stream == ^cursor.stream,
        where: c.phase == ^cursor.phase
      )
      |> Safe.unscoped()
      |> Safe.update_all(set: [completed_at: now, updated_at: now])

      :ok
    end

    def maybe_complete_backfill(_cursor), do: :ok

    def update_sink(sink, attrs) do
      changeset =
        Ecto.Changeset.cast(sink, attrs, [
          :error_message,
          :errored_at,
          :is_disabled,
          :disabled_reason,
          :is_verified
        ])

      {:ok, _sink} = changeset |> Safe.unscoped() |> Safe.update()
    end

    defp cursor_rows(sink, stream) do
      now = DateTime.utc_now()
      live_start = max_seq(stream, sink.account_id)

      live = %{
        account_id: sink.account_id,
        log_sink_id: sink.id,
        stream: stream,
        phase: :live,
        cursor: live_start,
        inserted_at: now,
        updated_at: now
      }

      if sink.retroactive and live_start > 0 do
        backfill = %{
          account_id: sink.account_id,
          log_sink_id: sink.id,
          stream: stream,
          phase: :backfill,
          cursor: 0,
          until_seq: live_start,
          backfill_total: count_up_to(stream, sink.account_id, live_start),
          inserted_at: now,
          updated_at: now
        }

        [live, backfill]
      else
        [live]
      end
    end

    defp max_seq(stream, account_id) do
      {schema, _guard_column} = Map.fetch!(@stream_sources, stream)

      from(l in schema,
        where: l.account_id == ^account_id,
        select: max(l.seq)
      )
      |> Safe.unscoped()
      |> Safe.one() || 0
    end

    defp count_up_to(stream, account_id, until_seq) do
      {schema, _guard_column} = Map.fetch!(@stream_sources, stream)

      from(l in schema,
        where: l.account_id == ^account_id,
        where: l.seq <= ^until_seq,
        select: count()
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
