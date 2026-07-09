defmodule Portal.ChangeLogs.Consumer do
  @moduledoc """
  Builds audit-log entries from the change_logs publication and inserts them
  keyed by LSN with `on_conflict: :nothing`, so the batch replays that slot
  polling delivers after a crash are idempotent.
  """
  @behaviour Portal.Replication.SlotPoller

  require Logger

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
    "devices" => Portal.Device,
    "email_otp_auth_providers" => Portal.EmailOTP.AuthProvider,
    "entra_auth_providers" => Portal.Entra.AuthProvider,
    "entra_directories" => Portal.Entra.Directory,
    "external_identities" => Portal.ExternalIdentity,
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
    "resources" => Portal.Resource,
    "sites" => Portal.Site,
    "static_device_pool_members" => Portal.StaticDevicePoolMember,
    "client_tokens" => Portal.ClientToken,
    "trust_anchor_certificates" => Portal.TrustAnchorCertificate,
    "trust_anchors" => Portal.TrustAnchor,
    "userpass_auth_providers" => Portal.Userpass.AuthProvider
  }

  @impl true
  def init_state(_config) do
    %{flush_buffer: %{}, tenant_offsets: %{}}
  end

  # Handle LogicalMessage to track subject info
  @impl true
  def on_logical_message(state, %{prefix: "subject", content: content, transactional: true}) do
    Map.put(state, :current_subject, content)
  end

  def on_logical_message(state, _message), do: state

  # Handle Begin to reset transaction state. On the first Begin of this
  # consumer's lifetime, seed seq_start from the Postgres clock so every
  # event_id this process emits shares a single authoritative timestamp.
  @impl true
  def on_begin(state, %{commit_timestamp: commit_timestamp}) do
    state
    |> Map.put_new_lazy(:seq_start, &Database.fetch_seq_start/0)
    |> Map.put_new(:tenant_offsets, %{})
    |> Map.delete(:current_subject)
    |> Map.put(:commit_timestamp, commit_timestamp)
  end

  # Handle accounts specially
  @impl true
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

  @impl true
  def flush(%{flush_buffer: flush_buffer} = state) when map_size(flush_buffer) == 0, do: state

  def flush(state) do
    attempted_count = map_size(state.flush_buffer)

    entries =
      state.flush_buffer
      |> Map.values()
      |> Enum.sort_by(& &1.lsn)

    inserted_count = Database.bulk_insert(entries)

    Logger.info("Flushed #{inserted_count}/#{attempted_count} change logs")

    %{state | flush_buffer: %{}}
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

    # Chunked to stay under the bind-parameter limit; each chunk is one
    # atomic statement, and a crash between chunks replays into lsn conflicts.
    @insert_chunk_size 500

    @doc """
    Inserts entries keyed by LSN. With a durable replication slot it's normal
    for WAL records to be replayed after a crash, so `on_conflict: :nothing`
    silently skips rows that already committed. Returns the inserted count.
    """
    def bulk_insert(entries) do
      entries = drop_missing_accounts(entries)

      entries
      |> Enum.chunk_every(@insert_chunk_size)
      |> Enum.reduce(0, fn chunk, inserted ->
        {count, _} =
          Safe.unscoped()
          |> Safe.insert_all(ChangeLog, chunk,
            on_conflict: :nothing,
            conflict_target: [:lsn]
          )

        inserted + count
      end)
    end

    # Entries for accounts that were hard-deleted since the WAL record was
    # written cannot be inserted (FK). An account deleted between this filter
    # and the insert still aborts the transaction; the poller replays the
    # batch and the filter catches it on the retry.
    defp drop_missing_accounts(entries) do
      account_ids = entries |> Enum.map(& &1.account_id) |> Enum.uniq()

      {:ok, %{rows: rows}} =
        Safe.unscoped()
        |> Safe.query("SELECT id::text FROM accounts WHERE id = ANY($1::text[]::uuid[])", [
          account_ids
        ])

      existing = MapSet.new(rows, fn [id] -> id end)
      {kept, dropped} = Enum.split_with(entries, &MapSet.member?(existing, &1.account_id))

      if dropped != [] do
        Logger.info(
          "Skipping #{length(dropped)} change log(s) because account no longer exists",
          account_ids: dropped |> Enum.map(& &1.account_id) |> Enum.uniq()
        )
      end

      kept
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
