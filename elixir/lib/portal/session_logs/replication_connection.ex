defmodule Portal.SessionLogs.ReplicationConnection do
  use Portal.Replication.Connection
  alias __MODULE__.Database
  alias Portal.Types.EventId

  @tables_to_contexts %{
    "client_sessions" => :client,
    "gateway_sessions" => :gateway,
    "portal_sessions" => :portal
  }

  # Handle Begin to track the commit timestamp for the transaction.
  def on_begin(state, %{commit_timestamp: commit_timestamp}) do
    Map.put(state, :commit_timestamp, commit_timestamp)
  end

  # Session logs record session creation only. The session row itself carries
  # the auth context (who connected, from where, with what), so we lift those
  # fields into columns instead of storing the row payload.
  def on_write(state, lsn, :insert, table, _old_data, %{"account_id" => account_id} = data)
      when is_map_key(@tables_to_contexts, table) and not is_nil(account_id) do
    buffer(state, lsn, table, account_id, data)
  end

  # Updates and deletes of session rows are lifecycle noise, not session events.
  def on_write(state, _lsn, op, table, _old_data, _data)
      when op in [:update, :delete] and is_map_key(@tables_to_contexts, table) do
    state
  end

  # If we get here, raise the alarm as it means we encountered a change we didn't expect.
  def on_write(state, lsn, op, table, _old_data, _data) do
    Logger.error(
      "Unexpected write operation!",
      lsn: lsn,
      op: op,
      table: table
    )

    state
  end

  def on_flush(%{flush_buffer: flush_buffer} = state) when map_size(flush_buffer) == 0, do: state

  def on_flush(state) do
    to_insert = Map.values(state.flush_buffer)
    attempted_count = Enum.count(state.flush_buffer)

    {successful_count, _skipped_count} = Database.bulk_insert(to_insert)

    Logger.info("Flushed #{successful_count}/#{attempted_count} session logs")

    # We always advance the LSN to the highest LSN in the flush buffer. Entries
    # for accounts that no longer exist are dropped during bulk_insert. LSN
    # conflicts are silently ignored for idempotency: after a crash/disconnect,
    # the replication slot replays records before the slot's confirmed_flush_lsn
    # is advanced, so we may insert the same LSN again on recovery.
    last_lsn =
      state.flush_buffer
      |> Map.keys()
      |> Enum.max()

    %{state | flush_buffer: %{}, last_flushed_lsn: last_lsn}
  end

  defp buffer(%{flush_buffer: flush_buffer} = state, lsn, _table, _account_id, _data)
       when is_map_key(flush_buffer, lsn) do
    state
  end

  defp buffer(
         %{flush_buffer: flush_buffer, commit_timestamp: commit_timestamp} = state,
         lsn,
         table,
         account_id,
         data
       ) do
    # Prefer the session row's own `timestamp` (captured at connect time);
    # `inserted_at` and the WAL commit timestamp both lag by the time the
    # entry spends in `Portal.Queue`. Rows written by code predating the
    # column fall back to the commit timestamp.
    entry = %{
      event_id: EventId.build_session_log(),
      timestamp: parse_timestamp(data["timestamp"]) || commit_timestamp,
      lsn: lsn,
      account_id: account_id,
      context: Map.fetch!(@tables_to_contexts, table),
      actor_id: data["actor_id"],
      actor_email: data["actor_email"],
      device_id: data["device_id"],
      token_id: data["client_token_id"] || data["gateway_token_id"],
      auth_provider_id: data["auth_provider_id"],
      user_agent: data["user_agent"],
      remote_ip: cast_ip(data["remote_ip"]),
      remote_ip_location_region: data["remote_ip_location_region"],
      remote_ip_location_city: data["remote_ip_location_city"],
      remote_ip_location_lat: parse_float(data["remote_ip_location_lat"]),
      remote_ip_location_lon: parse_float(data["remote_ip_location_lon"])
    }

    %{state | flush_buffer: Map.put(flush_buffer, lsn, entry)}
  end

  # WAL tuple data arrives as text; cast the fields we store as typed columns.
  # A value we cannot cast becomes nil rather than crashing the consumer.
  defp cast_ip(nil), do: nil

  defp cast_ip(value) do
    case Portal.Types.IP.cast(value) do
      {:ok, inet} -> inet
      _other -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(value) when is_float(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> nil
    end
  end

  defp parse_float(_value), do: nil

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp

  # The session `timestamp` column is timestamptz, so its WAL text carries a
  # UTC offset (e.g. "2026-06-10 18:00:00.5+00"). The offset-less fallback
  # guards against the column type ever changing, treating values as UTC.
  # :missing_offset means the value already parsed as a valid naive datetime,
  # so the NaiveDateTime parse cannot fail.
  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} ->
        pad_usec(timestamp)

      {:error, :missing_offset} ->
        {:ok, naive} = NaiveDateTime.from_iso8601(value)
        naive |> DateTime.from_naive!("Etc/UTC") |> pad_usec()

      {:error, _reason} ->
        nil
    end
  end

  defp parse_timestamp(_value), do: nil

  # Postgres trims trailing fractional zeros in WAL text; pad back to
  # microsecond precision so the value dumps as :utc_datetime_usec.
  defp pad_usec(%DateTime{microsecond: {usec, _precision}} = timestamp) do
    %{timestamp | microsecond: {usec, 6}}
  end

  defmodule Database do
    require Logger
    alias Portal.{Safe, SessionLog}

    def bulk_insert(list_of_attrs) do
      do_bulk_insert(list_of_attrs, 0)
    end

    # Public for tests: the raise guards a malformed batch we cannot build
    # through the real insert path.
    @doc false
    def split_missing_account(list_of_attrs, account_id) do
      {dropped, remaining} = Enum.split_with(list_of_attrs, &(&1.account_id == account_id))

      if dropped == [] do
        raise "session_logs account_id FK violation referenced account_id " <>
                "#{inspect(account_id)} that is not present in the batch"
      end

      {dropped, remaining}
    end

    # Pull the missing account_id out of the FK violation detail line, e.g.
    # `Key (account_id)=(c24f...) is not present in table "accounts".`. We have
    # already confirmed this is the account_id FK violation, so failing to parse
    # it means our assumptions about the error format broke: crash rather than
    # guess, otherwise we risk dropping valid entries or looping forever.
    # Public for tests: the raises guard error formats Postgres does not
    # produce today.
    @doc false
    def missing_account_id!(%{detail: detail}) when is_binary(detail) do
      case Regex.run(~r/\(account_id\)=\(([^)]+)\)/, detail) do
        [_, account_id] ->
          account_id

        nil ->
          raise "could not parse account_id from session_logs FK violation detail: " <>
                  inspect(detail)
      end
    end

    def missing_account_id!(pg) do
      raise "session_logs account_id FK violation has no usable detail: #{inspect(pg)}"
    end

    # Inserts the batch, transparently dropping entries that reference an account
    # that no longer exists and retrying with the remainder. A foreign-key
    # violation aborts the whole statement without inserting anything, so the
    # remaining valid entries are safe to re-attempt. We extract the offending
    # account_id from the error detail rather than querying `accounts` to keep
    # this hot, write-heavy path free of extra reads.
    #
    # Anything other than our account_id FK violation reraises so the replication
    # connection crashes and replays from the durable slot. If the violation is
    # ours but we cannot turn it into an account_id we can actually drop, we
    # raise loudly instead of silently swallowing the batch, so a change in the
    # constraint name or error format surfaces as a crash rather than data loss.
    defp do_bulk_insert([], skipped), do: {0, skipped}

    defp do_bulk_insert(list_of_attrs, skipped) do
      case insert_all(list_of_attrs) do
        {:ok, inserted} ->
          {inserted, skipped}

        {:missing_account, account_id} ->
          {dropped, remaining} = split_missing_account(list_of_attrs, account_id)

          Logger.info(
            "Skipping #{length(dropped)} session log(s) because account no longer exists",
            account_id: account_id
          )

          do_bulk_insert(remaining, skipped + length(dropped))
      end
    end

    defp insert_all(list_of_attrs) do
      # Use on_conflict: :nothing to make the insert idempotent. With a durable
      # replication slot, it's normal for WAL records to be replayed on reconnect
      # if we crash between inserting rows and advancing the slot's
      # confirmed_flush_lsn. Silently skipping re-inserted LSNs allows recovery.
      {inserted, _} =
        Safe.unscoped()
        |> Safe.insert_all(SessionLog, list_of_attrs,
          on_conflict: :nothing,
          conflict_target: [:lsn]
        )

      {:ok, inserted}
    rescue
      error in Postgrex.Error ->
        case error.postgres do
          %{code: :foreign_key_violation, constraint: "session_logs_account_id_fkey"} = pg ->
            {:missing_account, missing_account_id!(pg)}

          _ ->
            reraise error, __STACKTRACE__
        end
    end

  end
end
