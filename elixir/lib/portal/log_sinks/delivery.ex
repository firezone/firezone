defmodule Portal.LogSinks.Delivery do
  @moduledoc """
  Provider-agnostic log sink delivery engine.

  Each enabled stream is paged by a `Portal.LogSinkCursor` over the stream's
  `seq` column; the cursor only advances after the destination acknowledges
  the batch, so delivery is at-least-once. Cursors are seeded lazily on the
  first run: the `:live` cursor starts at the stream's current max seq, and a
  retroactive sink additionally gets a `:backfill` cursor covering everything
  before that.

  Provider specifics (envelope, batching format, HTTP, response reading) live
  in a `Portal.LogSinks.Adapter`. Errors follow the directory sync
  convention: an unrecoverable response disables the sink immediately,
  transient failures (408/429/5xx/transport) disable it only after 24 hours
  of continuous failure. An event the destination rejects outright parks its
  stream and pages us with no customer-facing state at all: failing to map
  our own data is our bug to fix, not the admin's. Nothing here can re-enable a disabled sink.
  """

  alias __MODULE__.Database

  require Logger

  @batch_size 500
  # Bounds one run; the next scheduler tick resumes from the cursor.
  @max_batches_per_stream 20

  def get_sink(schema, id) do
    Database.get_sink(schema, id)
  end

  def sync(sink, adapter) do
    Database.seed_missing_cursors(sink)

    result =
      Enum.reduce_while(Database.list_cursors(sink), :ok, fn cursor, :ok ->
        case sync_cursor(sink, adapter, cursor, @max_batches_per_stream) do
          :ok -> {:cont, :ok}
          {:error, :undeliverable} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok -> handle_success(sink)
      {:error, reason} -> handle_error(sink, adapter, reason)
    end

    :ok
  end

  # Rows younger than this are not delivered yet: a row whose seq was assigned
  # in an uncommitted transaction could otherwise be leapfrogged by the cursor.
  # Close-updated flow rows keep their original inserted_at, so for them this
  # guard does not apply and a sub-second race remains; acceptable for now.
  defp visibility_lag_seconds do
    Application.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:visibility_lag_seconds, 30)
  end

  # Stays well under the smallest destination request cap (Splunk Cloud: 1 MB).
  defp max_body_bytes do
    Application.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:max_body_bytes, 512_000)
  end

  defp sync_cursor(_sink, _adapter, _cursor, 0), do: :ok

  defp sync_cursor(sink, adapter, cursor, budget) do
    case Database.next_batch(cursor, @batch_size, visibility_lag_seconds()) do
      [] ->
        Database.maybe_complete_backfill(cursor, visibility_lag_seconds())
        :ok

      rows ->
        deliver_batch(sink, adapter, cursor, rows, budget)
    end
  end

  defp deliver_batch(sink, adapter, cursor, rows, budget) do
    encoded =
      Enum.flat_map(rows, fn row ->
        for event <- render_event(cursor.stream, row, cursor.cursor) do
          {row.seq, adapter.encode_event(sink, cursor.stream, event)}
        end
      end)

    case deliver_chunks(sink, adapter, cursor, chunk_by_bytes(encoded, max_body_bytes())) do
      {:ok, cursor} -> sync_cursor(sink, adapter, cursor, budget - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_chunks(_sink, _adapter, cursor, []), do: {:ok, cursor}

  defp deliver_chunks(sink, adapter, cursor, [chunk | rest]) do
    case deliver_chunk(sink, adapter, cursor, chunk) do
      {:ok, cursor} -> deliver_chunks(sink, adapter, cursor, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_chunk(sink, adapter, cursor, chunk) do
    body = adapter.join_batch(Enum.map(chunk, fn {_seq, json} -> json end))
    max_seq = chunk |> Enum.map(fn {seq, _json} -> seq end) |> Enum.max()

    case adapter.post_batch(sink, body) do
      {:ok, %Req.Response{} = response} ->
        case adapter.interpret(sink, response) do
          :accepted ->
            advance(cursor, max_seq, length(chunk), 0)

          :payload_too_large ->
            handle_rejected_chunk(sink, adapter, cursor, chunk, response, :oversized)

          :malformed_payload ->
            handle_rejected_chunk(sink, adapter, cursor, chunk, response, :malformed)

          :retriable ->
            {:error, {:retriable, response}}

          :failed ->
            {:error, {:status, response}}
        end

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # A single event the destination rejects is never skipped: the cursor parks
  # on it and the error pages us with the exact request and response, every
  # run, until we fix the cause and delivery resumes with nothing lost. The
  # sink's customer-facing state stays untouched and other streams keep
  # flowing. A rejected multi-event chunk is bisected until the offender is
  # isolated, delivering the healthy events along the way.
  defp handle_rejected_chunk(_sink, _adapter, cursor, [{seq, json}] = _chunk, response, reason) do
    Logger.error("Log sink event cannot be delivered, halting stream",
      log_sink_id: cursor.log_sink_id,
      account_id: cursor.account_id,
      stream: cursor.stream,
      seq: seq,
      reason: reason,
      request_bytes: byte_size(json),
      request: binary_part(json, 0, min(byte_size(json), 65_536)),
      response_status: response.status,
      response_body: response.body
    )

    {:error, :undeliverable}
  end

  defp handle_rejected_chunk(sink, adapter, cursor, chunk, _response, _reason) do
    {left, right} = Enum.split(chunk, div(length(chunk), 2))

    with {:ok, cursor} <- deliver_chunk(sink, adapter, cursor, left) do
      deliver_chunk(sink, adapter, cursor, right)
    end
  end

  defp advance(cursor, new_seq, delivered, dropped) do
    case Database.advance_cursor(cursor, new_seq, delivered, dropped) do
      {:ok, cursor} -> {:ok, cursor}
      :error -> {:error, :cursor_conflict}
    end
  end

  # Same-seq events (a flow's start/end pair) never split across chunks: the
  # cursor advances past their seq when a chunk lands, so a crash between
  # chunks could otherwise lose the trailing half of the pair.
  defp chunk_by_bytes(encoded, max_bytes) do
    encoded
    |> Enum.chunk_by(fn {seq, _json} -> seq end)
    |> Enum.chunk_while(
      {[], 0},
      fn group, {acc, bytes} ->
        size = group |> Enum.map(fn {_seq, json} -> byte_size(json) + 1 end) |> Enum.sum()

        cond do
          acc == [] -> {:cont, {[group], size}}
          bytes + size > max_bytes -> {:cont, flatten_groups(acc), {[group], size}}
          true -> {:cont, {[group | acc], bytes + size}}
        end
      end,
      fn
        {[], _bytes} -> {:cont, []}
        {acc, _bytes} -> {:cont, flatten_groups(acc), []}
      end
    )
  end

  defp flatten_groups(reversed_groups) do
    reversed_groups |> Enum.reverse() |> List.flatten()
  end

  # Clears transient error streaks only. A disabled sink never syncs, so
  # nothing here can re-enable one: that is reserved for an admin editing it.
  defp handle_success(sink) do
    Database.update_sink(sink, %{
      "error_message" => nil,
      "errored_at" => nil,
      "error_email_count" => 0
    })
  end

  defp handle_error(sink, adapter, reason) do
    now = DateTime.utc_now()
    message = format_error(adapter, reason)

    Logger.warning("Log sink sync failed",
      log_sink_id: sink.id,
      account_id: sink.account_id,
      reason: message
    )

    case classify(reason) do
      :client_error ->
        Database.update_sink(sink, %{
          "errored_at" => now,
          "error_message" => message,
          "is_disabled" => true,
          "disabled_reason" => "Sync error"
        })

      :transient ->
        errored_at = sink.errored_at || now
        updates = %{"errored_at" => errored_at, "error_message" => message}

        updates =
          if DateTime.diff(now, errored_at, :hour) >= 24 do
            Map.merge(updates, %{
              "is_disabled" => true,
              "disabled_reason" => "Sync error"
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
  defp classify({:retriable, _response}), do: :transient
  defp classify({:transport, _exception}), do: :transient
  defp classify(:cursor_conflict), do: :transient

  defp format_error(adapter, {:status, %Req.Response{} = response}) do
    adapter.format_status_error(response)
  end

  defp format_error(adapter, {:retriable, %Req.Response{} = response}) do
    adapter.format_status_error(response)
  end

  defp format_error(_adapter, {:transport, exception}) do
    Portal.DirectorySync.ErrorHandler.format_transport_error(exception)
  end

  defp format_error(_adapter, :cursor_conflict), do: "Concurrent sync detected."

  defp render_event(:change, log, _batch_floor) do
    [
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
    ]
  end

  defp render_event(:session, log, _batch_floor) do
    [
      {epoch(log.timestamp),
     %{
       type: "session",
       log_id: log.log_id,
       timestamp: log.timestamp,
       context: log.context,
       subject: log.subject
     }}
    ]
  end

  defp render_event(:api_request, log, _batch_floor) do
    [
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
    ]
  end

  # A flow yields two logical events sharing its log_id. The close bumps seq
  # and replaces the open-state row, so a sink that was not live for the open
  # phase (backfills, fast-closing flows) would otherwise never see a start
  # event: a closed row therefore renders as a start/end pair. Sinks that
  # already delivered the start at open time redeliver it here; (log_id,
  # phase) stays the dedup key, and destinations with _id semantics collapse
  # it entirely.
  defp render_event(:flow, %{flow_end: nil} = log, _batch_floor) do
    [flow_event(log, "-s", log.flow_start)]
  end

  # A closed row is the only version left of the flow, so the start event is
  # synthesized unless this sink already delivered it: start_seq records the
  # open-state seq the close replaced, and the frontier can only have swept
  # that version if it lies at or below where this batch started. Suffixed
  # log_ids make log_id alone the dedup key everywhere.
  defp render_event(:flow, log, batch_floor) do
    end_event = flow_event(log, "-e", log.flow_end)

    if is_nil(log.start_seq) or log.start_seq > batch_floor do
      open = %{
        log
        | flow_end: nil,
          last_packet: nil,
          rx_packets: nil,
          tx_packets: nil,
          rx_bytes: nil,
          tx_bytes: nil
      }

      [flow_event(open, "-s", log.flow_start), end_event]
    else
      [end_event]
    end
  end

  defp flow_event(log, suffix, time) do
    {epoch(time),
     %{
       type: "flow",
       log_id: log.log_id <> suffix,
       timestamp: time,
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

    @stream_sources %{
      change: {Portal.ChangeLog, :timestamp},
      session: {Portal.SessionLog, :timestamp},
      api_request: {Portal.APIRequestLog, :inserted_at},
      flow: {Portal.FlowLog, :inserted_at}
    }

    def get_sink(schema, id) do
      from(s in schema,
        join: a in Portal.Account,
        on: a.id == s.account_id,
        where: s.id == ^id,
        where: s.is_disabled == false,
        where: is_nil(a.disabled_at),
        where: fragment("(?)->>'log_sinks' = 'true'", a.features)
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

    # An empty guarded batch is not proof the backfill is done: rows at or
    # below until_seq may still be hidden by the visibility lag, or not yet
    # committed at all if their transaction was in flight when the cursor was
    # seeded. Complete only once nothing remains without the lag guard AND
    # the cursor has existed for a full lag window, so late writers landed.
    def maybe_complete_backfill(%LogSinkCursor{phase: :backfill, completed_at: nil} = cursor, lag_seconds) do
      if backfill_drained?(cursor) and older_than_lag?(cursor, lag_seconds) do
        now = DateTime.utc_now()

        from(c in LogSinkCursor,
          where: c.account_id == ^cursor.account_id,
          where: c.log_sink_id == ^cursor.log_sink_id,
          where: c.stream == ^cursor.stream,
          where: c.phase == ^cursor.phase
        )
        |> Safe.unscoped()
        |> Safe.update_all(set: [completed_at: now, updated_at: now])
      end

      :ok
    end

    def maybe_complete_backfill(_cursor, _lag_seconds), do: :ok

    def update_sink(sink, attrs) do
      changeset =
        Ecto.Changeset.cast(sink, attrs, [
          :error_message,
          :errored_at,
          :error_email_count,
          :is_disabled,
          :disabled_reason
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

    defp backfill_drained?(cursor) do
      {schema, _guard_column} = Map.fetch!(@stream_sources, cursor.stream)

      from(l in schema,
        where: l.account_id == ^cursor.account_id,
        where: l.seq > ^cursor.cursor,
        where: l.seq <= ^cursor.until_seq,
        select: true,
        limit: 1
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> is_nil()
    end

    defp older_than_lag?(cursor, lag_seconds) do
      cutoff = DateTime.add(DateTime.utc_now(), -lag_seconds, :second)
      DateTime.before?(cursor.inserted_at, cutoff)
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
