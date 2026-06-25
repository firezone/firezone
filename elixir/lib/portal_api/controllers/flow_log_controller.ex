defmodule PortalAPI.FlowLogController do
  # This endpoint is intentionally omitted from the OpenAPI spec. It is not part
  # of the public REST API: it exists solely for Clients and Gateways to batch-post
  # their flow logs, and is not meant to be called by API consumers. That is why
  # this controller deliberately does not `use OpenApiSpex.ControllerSpecs` and
  # declares no `operation`/`request_body` specs (which is what would otherwise
  # cause `Paths.from_router/1` to document it).
  #
  # There is no request-level authentication: each record carries its own
  # per-flow ingest token (see `Portal.FlowLogToken`), which both authenticates
  # the record and supplies the authoritative attribution fields (account,
  # policy, resource, actor, reporting device + role). The body supplies the
  # network fields: the inner tunnel tuple, the outer (WireGuard) tuple, the
  # flow window, and the byte/packet counters.
  use PortalAPI, :controller
  import Ecto.Changeset
  alias Portal.FlowLog
  alias Portal.FlowLogToken
  alias Portal.Types.EventId
  alias PortalAPI.ProblemDetails
  alias __MODULE__.Database

  # Schema fields we cast/persist. `event_id` is server-assigned per record (a
  # fresh flow_log event_id is minted here, not trusted from the body); on a
  # slot conflict the existing row keeps its own event_id. Attribution fields
  # come from the token; the rest are reported in the body.
  @cast_fields ~w[account_id event_id device_id role policy_id auth_provider_id resource_id
                  resource_name resource_address actor_id actor_email actor_name authorized_at
                  authorization_expires_at
                  client_version
                  device_os_name device_os_version device_serial device_uuid
                  device_identifier_for_vendor device_firebase_installation_id protocol
                  inner_src_ip inner_dst_ip inner_src_port inner_dst_port domain
                  outer_src_ip outer_dst_ip outer_src_port outer_dst_port flow_start flow_end
                  last_packet rx_packets tx_packets rx_bytes tx_bytes inserted_at]a

  @max_batch_size 10_000

  def create(conn, %{"flow_logs" => records})
      when is_list(records) and length(records) > @max_batch_size do
    ProblemDetails.send(conn, 400, "Batch size exceeds maximum of #{@max_batch_size}")
  end

  def create(conn, %{"flow_logs" => records}) when is_list(records) do
    now = DateTime.utc_now()

    {valid, errors, _key_cache} =
      records
      |> Enum.with_index()
      |> Enum.reduce({[], [], %{}}, fn {record, index}, acc ->
        validate_record(record, index, now, acc)
      end)

    valid
    |> Enum.map(fn {_index, entry} -> entry end)
    |> Database.upsert_flow_logs()

    if errors == [] do
      conn
      |> put_status(202)
      |> put_view(json: PortalAPI.FlowLogJSON)
      |> render(:accepted)
    else
      ProblemDetails.send(conn, 422, "Some flow log records failed validation", %{
        validation_errors: render_validation_errors(Enum.reverse(errors))
      })
    end
  end

  def create(conn, _params) do
    ProblemDetails.send(conn, 400, "Expected a \"flow_logs\" array")
  end

  # Threads {valid, errors, key_cache}: valid is a list of {index, entry},
  # errors a list of {index, reason}, and key_cache memoizes each account's
  # signing key for the request so a batch under one account hits the DB once.
  defp validate_record(record, index, _now, {valid, invalid, cache})
       when not is_map(record) do
    {valid, [{index, :not_a_map} | invalid], cache}
  end

  defp validate_record(record, index, now, {valid, invalid, cache}) do
    case FlowLogToken.verify(Map.get(record, "token"), cache) do
      {{:ok, claims}, cache} ->
        changeset =
          record
          |> to_attrs(claims, now)
          |> changeset()

        if changeset.valid? do
          entry = Map.new(@cast_fields, &{&1, get_field(changeset, &1)})
          {[{index, entry} | valid], invalid, cache}
        else
          {valid, [{index, changeset} | invalid], cache}
        end

      {{:error, reason}, cache} ->
        {valid, [{index, {:token, reason}} | invalid], cache}
    end
  end

  defp changeset(attrs) do
    %FlowLog{}
    |> cast(attrs, @cast_fields)
    |> FlowLog.changeset()
  end

  defp render_validation_errors(errors) do
    Map.new(errors, fn
      {index, :not_a_map} ->
        {index, %{record: ["must be a JSON object"]}}

      {index, {:token, reason}} ->
        {index, %{token: ["is #{reason}"]}}

      {index, changeset} ->
        {index, Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
    end)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  # The only fields a reporter may supply: the network tuples, flow window, and
  # counters. Everything else (attribution, event_id, inserted_at) is set from
  # the verified token or the server below.
  @body_fields ~w[protocol inner_src_ip inner_dst_ip inner_src_port inner_dst_port domain
                  outer_src_ip outer_dst_ip outer_src_port outer_dst_port
                  flow_start flow_end last_packet rx_packets tx_packets rx_bytes tx_bytes]

  # Attribution comes from the verified token (authoritative); the network
  # fields, flow window, and counters come from the body. Taking the body fields
  # as an explicit whitelist means a record can never supply its own attribution
  # (account, device, role, policy, resource, actor) or the server-assigned
  # event_id, regardless of what keys it sends.
  defp to_attrs(record, claims, now) do
    record
    |> Map.take(@body_fields)
    |> Map.merge(%{
      "account_id" => claims["account_id"],
      "event_id" => EventId.build_flow_log(),
      "device_id" => claims["device_id"],
      "role" => claims["role"],
      "policy_id" => claims["policy_id"],
      "auth_provider_id" => claims["auth_provider_id"],
      "resource_id" => claims["resource_id"],
      "resource_name" => claims["resource_name"],
      "resource_address" => claims["resource_address"],
      "actor_id" => claims["actor_id"],
      "actor_email" => claims["actor_email"],
      "actor_name" => claims["actor_name"],
      "authorized_at" => claims["authorized_at"],
      "authorization_expires_at" => claims["authorization_expires_at"],
      "client_version" => claims["client_version"],
      "device_os_name" => claims["device_os_name"],
      "device_os_version" => claims["device_os_version"],
      "device_serial" => claims["device_serial"],
      "device_uuid" => claims["device_uuid"],
      "device_identifier_for_vendor" => claims["device_identifier_for_vendor"],
      "device_firebase_installation_id" => claims["device_firebase_installation_id"],
      "inserted_at" => now
    })
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.FlowLog
    alias Portal.Safe

    @identity_columns [
      :account_id,
      :device_id,
      :role,
      :flow_start,
      :protocol,
      :inner_src_ip,
      :inner_src_port,
      :inner_dst_ip,
      :inner_dst_port,
      :resource_id
    ]

    def upsert_flow_logs([]), do: :ok

    def upsert_flow_logs(entries) do
      Safe.unscoped()
      |> Safe.insert_all(FlowLog, dedup_by_identity(entries),
        on_conflict: on_conflict_query(),
        conflict_target: @identity_columns
      )
    end

    # The conflict target is the full flow identity, so a collision is always a
    # re-report of the same flow. The update runs once, on the open->close
    # transition (a still-open row receiving its close); a replayed open, a
    # replayed close, or a late open arriving after the close all leave the row
    # untouched, so an open never churns the row and a closed flow is immutable.
    # The attribution snapshot, both tunnel tuples, and domain are stable for the
    # life of a flow and are only ever set on insert.
    defp on_conflict_query do
      from(f in FlowLog,
        update: [
          set: [
            flow_end: fragment("EXCLUDED.flow_end"),
            last_packet: fragment("EXCLUDED.last_packet"),
            rx_packets: fragment("EXCLUDED.rx_packets"),
            tx_packets: fragment("EXCLUDED.tx_packets"),
            rx_bytes: fragment("EXCLUDED.rx_bytes"),
            tx_bytes: fragment("EXCLUDED.tx_bytes")
          ]
        ],
        where: is_nil(f.flow_end) and fragment("EXCLUDED.flow_end IS NOT NULL")
      )
    end

    # insert_all cannot affect one conflict target twice in a single statement,
    # so collapse multiple reports of the same flow within a batch (e.g. an open
    # and its close) into one row, preferring the close (it carries flow_end and
    # the counters).
    defp dedup_by_identity(entries) do
      entries
      |> Enum.group_by(&identity/1)
      |> Enum.map(fn {_identity, group} ->
        Enum.find(group, hd(group), fn e -> not is_nil(e.flow_end) end)
      end)
    end

    defp identity(e) do
      {e.account_id, e.device_id, e.role, e.flow_start, e.protocol, e.inner_src_ip,
       e.inner_src_port, e.inner_dst_ip, e.inner_dst_port, e.resource_id}
    end
  end
end
