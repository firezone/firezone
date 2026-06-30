defmodule Portal.ChangeLogs.ReplicationConnection do
  use Portal.Replication.Connection
  alias __MODULE__.Database
  alias Portal.Types.EventId

  # Bump this to signify a change in the audit log schema. Use with care.
  @vsn 0

  # This will be inserted into the change log to indicate that the data has been redacted
  @redacted "[redacted]"

  # Used to introspect field redactions
  @tables_to_schemas %{
    "accounts" => Portal.Account,
    "actors" => Portal.Actor,
    "api_tokens" => Portal.APIToken,
    "client_sessions" => Portal.ClientSession,
    "devices" => Portal.Device,
    "email_otp_auth_providers" => Portal.EmailOTP.AuthProvider,
    "entra_auth_providers" => Portal.Entra.AuthProvider,
    "entra_directories" => Portal.Entra.Directory,
    "external_identities" => Portal.ExternalIdentity,
    "gateway_sessions" => Portal.GatewaySession,
    "gateway_tokens" => Portal.GatewayToken,
    "google_auth_providers" => Portal.Google.AuthProvider,
    "google_directories" => Portal.Google.Directory,
    "groups" => Portal.Group,
    "memberships" => Portal.Membership,
    "oidc_auth_providers" => Portal.OIDC.AuthProvider,
    "okta_auth_providers" => Portal.Okta.AuthProvider,
    "okta_directories" => Portal.Okta.Directory,
    "one_time_passcodes" => Portal.OneTimePasscode,
    "policies" => Portal.Policy,
    "portal_sessions" => Portal.PortalSession,
    "resources" => Portal.Resource,
    "sites" => Portal.Site,
    "static_device_pool_members" => Portal.StaticDevicePoolMember,
    "client_tokens" => Portal.ClientToken,
    "trust_anchor_certificates" => Portal.TrustAnchorCertificate,
    "trust_anchors" => Portal.TrustAnchor,
    "userpass_auth_providers" => Portal.Userpass.AuthProvider
  }

  # Handle LogicalMessage to track subject info
  def on_logical_message(state, %{prefix: "subject", content: content, transactional: true}) do
    Map.put(state, :current_subject, content)
  end

  def on_logical_message(state, _message), do: state

  # Handle Begin to reset transaction state. On the first Begin of this
  # consumer's lifetime, seed seq_start from the Postgres clock so every
  # event_id this process emits shares a single authoritative timestamp.
  def on_begin(state, %{commit_timestamp: commit_timestamp}) do
    state
    |> Map.put_new_lazy(:seq_start, &Database.fetch_seq_start/0)
    |> Map.put_new(:tenant_offsets, %{})
    |> Map.delete(:current_subject)
    |> Map.put(:commit_timestamp, commit_timestamp)
  end

  # Handle accounts specially
  def on_write(state, lsn, op, "accounts", %{"id" => account_id} = old_data, data) do
    {old_data, data} = redact_from_schema("accounts", old_data, data)
    buffer(state, lsn, op, "accounts", account_id, old_data, data)
  end

  def on_write(state, lsn, op, "accounts", old_data, %{"id" => account_id} = data) do
    {old_data, data} = redact_from_schema("accounts", old_data, data)
    buffer(state, lsn, op, "accounts", account_id, old_data, data)
  end

  # Handle other writes where an account_id is present
  def on_write(state, lsn, op, table, old_data, %{"account_id" => account_id} = data)
      when not is_nil(account_id) do
    {old_data, data} = redact_from_schema(table, old_data, data)
    buffer(state, lsn, op, table, account_id, old_data, data)
  end

  def on_write(state, lsn, op, table, %{"account_id" => account_id} = old_data, data)
      when not is_nil(account_id) do
    {old_data, data} = redact_from_schema(table, old_data, data)
    buffer(state, lsn, op, table, account_id, old_data, data)
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

    Logger.info("Flushed #{successful_count}/#{attempted_count} change logs")

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

  defp buffer(
         %{flush_buffer: flush_buffer} = state,
         lsn,
         _op,
         _table,
         _account_id,
         _old_data,
         _data
       )
       when is_map_key(flush_buffer, lsn) do
    state
  end

  defp buffer(
         %{
           flush_buffer: flush_buffer,
           commit_timestamp: commit_timestamp,
           seq_start: seq_start,
           tenant_offsets: tenant_offsets
         } = state,
         lsn,
         op,
         table,
         account_id,
         old_data,
         data
       ) do
    offset = Map.get(tenant_offsets, account_id, 0)

    entry = %{
      event_id: EventId.build_change_log(seq_start, offset),
      timestamp: commit_timestamp,
      lsn: lsn,
      operation: op,
      object: table,
      account_id: account_id,
      before: old_data,
      after: data,
      subject: decode_subject(state),
      vsn: @vsn
    }

    %{
      state
      | flush_buffer: Map.put(flush_buffer, lsn, entry),
        tenant_offsets: Map.put(tenant_offsets, account_id, offset + 1)
    }
  end

  defp decode_subject(%{current_subject: nil}), do: nil

  defp decode_subject(%{current_subject: json_string}) when is_binary(json_string) do
    case JSON.decode(json_string) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp decode_subject(_state), do: nil

  # Field redactions - introspects schema to redact sensitive fields

  defp redact_from_schema(table, old_data, data) do
    schema_module = Map.get(@tables_to_schemas, table)

    if schema_module do
      fields_to_redact = schema_module.__schema__(:redact_fields)
      redacted_old_data = redact_fields(old_data, fields_to_redact)
      redacted_data = redact_fields(data, fields_to_redact)
      {redacted_old_data, redacted_data}
    else
      {old_data, data}
    end
  end

  defp redact_fields(nil, _fields), do: nil

  defp redact_fields(map, fields) when is_map(map) and is_list(fields) do
    Enum.reduce(fields, map, fn field, acc ->
      field = to_string(field)

      if Map.has_key?(acc, field) do
        Map.put(acc, field, @redacted)
      else
        acc
      end
    end)
  end

  defmodule Database do
    require Logger
    alias Portal.{Safe, ChangeLog}

    def bulk_insert(list_of_attrs) do
      do_bulk_insert(list_of_attrs, 0)
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
          {dropped, remaining} = Enum.split_with(list_of_attrs, &(&1.account_id == account_id))

          if dropped == [] do
            raise "change_logs account_id FK violation referenced account_id " <>
                    "#{inspect(account_id)} that is not present in the batch"
          end

          Logger.info(
            "Skipping #{length(dropped)} change log(s) because account no longer exists",
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
        |> Safe.insert_all(ChangeLog, list_of_attrs,
          on_conflict: :nothing,
          conflict_target: [:lsn]
        )

      {:ok, inserted}
    rescue
      error in Postgrex.Error ->
        case error.postgres do
          %{code: :foreign_key_violation, constraint: "change_logs_account_id_fkey"} = pg ->
            {:missing_account, missing_account_id!(pg)}

          _ ->
            reraise error, __STACKTRACE__
        end
    end

    # Pull the missing account_id out of the FK violation detail line, e.g.
    # `Key (account_id)=(c24f...) is not present in table "accounts".`. We have
    # already confirmed this is the account_id FK violation, so failing to parse
    # it means our assumptions about the error format broke: crash rather than
    # guess, otherwise we risk dropping valid entries or looping forever.
    defp missing_account_id!(%{detail: detail}) when is_binary(detail) do
      case Regex.run(~r/\(account_id\)=\(([^)]+)\)/, detail) do
        [_, account_id] ->
          account_id

        nil ->
          raise "could not parse account_id from change_logs FK violation detail: " <>
                  inspect(detail)
      end
    end

    defp missing_account_id!(pg) do
      raise "change_logs account_id FK violation has no usable detail: #{inspect(pg)}"
    end

    # Read seq_start from Postgres so we always use a consistent clock source.
    def fetch_seq_start do
      {:ok, %{rows: [[seq_start]]}} =
        Safe.unscoped()
        |> Safe.query("SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000000)::bigint", [])

      seq_start
    end
  end
end
