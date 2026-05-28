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
    "outbound_emails" => Portal.OutboundEmail,
    "outbound_email_deliveries" => Portal.OutboundEmailDelivery,
    "userpass_auth_providers" => Portal.Userpass.AuthProvider
  }

  # Handle LogicalMessage to track subject info
  def on_logical_message(state, %{prefix: "subject", content: content, transactional: true}) do
    Map.put(state, :current_subject, content)
  end

  def on_logical_message(state, _message), do: state

  # Handle Begin to reset transaction state
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

    {successful_count, _change_logs} = Database.bulk_insert(to_insert)

    Logger.info("Flushed #{successful_count}/#{attempted_count} change logs")

    # We always advance the LSN to the highest LSN in the flush buffer because
    # LSN conflicts just mean the data is already inserted, and other insert_all
    # issues like a missing account_id will raise an exception.
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
      op: op,
      table: table,
      account_id: account_id,
      old_data: old_data,
      data: data,
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
    alias Portal.{Safe, ChangeLog}

    def bulk_insert(list_of_attrs) do
      Safe.unscoped()
      |> Safe.insert_all(ChangeLog, list_of_attrs,
        on_conflict: :nothing,
        conflict_target: [:lsn]
      )
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
