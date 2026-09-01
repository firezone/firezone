defmodule PortalAPI.FlowLogController do
  # The request carries a single per-authorization ingest token (see
  # `Portal.FlowLogToken`) in the `Authorization: Bearer` header. It both
  # authenticates the request and supplies the authoritative attribution fields
  # (account, policy authorization, policy, resource, actor, both endpoint
  # devices + which of them is reporting) for every record. Because the token
  # names one policy authorization, a
  # request may only carry flow logs for that authorization: a record declaring
  # a different `policy_authorization_id` fails the whole request with 422. The
  # body supplies the network fields: the inner tunnel tuple, the ordered outer
  # (WireGuard) paths, the flow window, and the byte/packet counters.
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  import Ecto.Changeset
  alias OpenApiSpex.Schema
  alias Portal.FlowLog
  alias Portal.Types.LogId
  alias PortalAPI.ProblemDetails
  alias PortalAPI.Schemas.ProblemDetails, as: ProblemDetailsSchema
  alias __MODULE__.Database

  # ApiSpec resolves this operation to retain its request schemas as a versioned
  # contract, then removes the private ingestion path from the published API.
  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Ingest Flow Logs",
    request_body:
      {"Flow Log batch", "application/json", PortalAPI.Schemas.FlowLogIngest.Request,
       required: true},
    responses:
      [
        ok:
          {"Flow Logs accepted", "application/json",
           %Schema{
             type: :object,
             required: [:data],
             properties: %{
               data: %Schema{
                 type: :object,
                 required: [:status],
                 properties: %{status: %Schema{type: :string, enum: ["ok"]}}
               }
             }
           }}
      ] ++
        ProblemDetailsSchema.responses([
          :bad_request,
          :unauthorized,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  # Schema fields we cast/persist. `log_id` is server-assigned per record (a
  # fresh flow_log log_id is minted here, not trusted from the body); on a
  # slot conflict the existing row keeps its own log_id. Attribution fields
  # come from the token; the rest are reported in the body.
  @cast_fields ~w[account_id log_id initiator_device_id responder_device_id role
                  policy_authorization_id policy_id
                  initiator_auth_provider_id resource_id
                  resource_name resource_address initiator_actor_id initiator_actor_email
                  initiator_actor_name authorized_at
                  authorization_expires_at
                  initiator_client_version
                  initiator_device_os_name initiator_device_os_version initiator_device_serial
                  initiator_device_uuid initiator_device_identifier_for_vendor
                  initiator_device_firebase_installation_id protocol
                  inner_src_ip inner_dst_ip inner_src_port inner_dst_port domain
                  outers flow_start flow_end
                  last_packet rx_packets tx_packets rx_bytes tx_bytes inserted_at]a

  @scalar_cast_fields @cast_fields -- [:outers]

  @max_batch_size 10_000

  def create(conn, %{"flow_logs" => records})
      when is_list(records) and length(records) > @max_batch_size do
    ProblemDetails.send(conn, 400, "Batch size exceeds maximum of #{@max_batch_size}")
  end

  def create(conn, %{"flow_logs" => records}) when is_list(records) do
    claims = conn.assigns.flow_log_claims

    with :ok <- ensure_single_authorization(records, claims) do
      now = DateTime.utc_now()

      {valid, errors} =
        records
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {record, index}, acc ->
          validate_record(record, index, claims, now, acc)
        end)

      valid
      |> Enum.map(fn {_index, entry} -> entry end)
      |> Database.upsert_flow_logs()

      if errors == [] do
        conn
        |> put_status(200)
        |> put_view(json: PortalAPI.FlowLogJSON)
        |> render(:ok)
      else
        ProblemDetails.send(conn, 422, "Some flow log records failed validation", %{
          validation_errors: render_validation_errors(Enum.reverse(errors))
        })
      end
    else
      {:error, :multiple_authorizations} ->
        ProblemDetails.send(
          conn,
          422,
          "All flow logs in a request must belong to a single policy authorization"
        )
    end
  end

  def create(conn, _params) do
    ProblemDetails.send(conn, 400, "Expected a \"flow_logs\" array")
  end

  # The token names exactly one policy authorization; a record that declares a
  # different one means the reporter mixed authorizations into one request, which
  # fails the whole request. A record omitting the id is attributed to the
  # token's authorization (attribution always comes from the token regardless).
  defp ensure_single_authorization(records, %{"policy_authorization_id" => authz_id}) do
    mixed? =
      Enum.any?(records, fn
        record when is_map(record) ->
          case Map.get(record, "policy_authorization_id") do
            nil -> false
            id -> id != authz_id
          end

        _ ->
          false
      end)

    if mixed? do
      {:error, :multiple_authorizations}
    else
      :ok
    end
  end

  defp ensure_single_authorization(_records, _claims), do: {:error, :unauthenticated}

  # Threads {valid, errors}: valid is a list of {index, entry} and errors a list
  # of {index, reason}. Attribution comes from the request token (claims), so a
  # record only needs structural validation of its body.
  defp validate_record(record, index, _claims, _now, {valid, invalid})
       when not is_map(record) do
    {valid, [{index, :not_a_map} | invalid]}
  end

  defp validate_record(record, index, claims, now, {valid, invalid}) do
    changeset =
      record
      |> to_attrs(claims, now)
      |> changeset()

    if changeset.valid? do
      entry =
        @cast_fields
        |> Map.new(&{&1, get_field(changeset, &1)})
        |> Map.put(:outers, outers_for_storage(changeset))

      {[{index, entry} | valid], invalid}
    else
      {valid, [{index, changeset} | invalid]}
    end
  end

  defp changeset(attrs) do
    # Ecto represents a missing embeds_many value as an empty list but rejects
    # an explicit JSON null. Both forms mean "not reported yet" on a flow-start
    # record, so normalize null to omission before casting. A close still fails
    # validation below when the resulting outer list is empty.
    attrs = if is_nil(attrs["outers"]), do: Map.delete(attrs, "outers"), else: attrs

    %FlowLog{}
    |> cast(attrs, @scalar_cast_fields)
    |> FlowLog.changeset()
  end

  defp outers_for_storage(changeset) do
    case get_field(changeset, :outers) do
      [] -> nil
      outers -> outers
    end
  end

  defp render_validation_errors(errors) do
    Map.new(errors, fn
      {index, :not_a_map} ->
        {index, %{record: ["must be a JSON object"]}}

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
  # counters. Everything else (attribution, log_id, inserted_at) is set from
  # the verified token or the server below.
  @body_fields ~w[protocol inner_src_ip inner_dst_ip inner_src_port inner_dst_port domain
                  outers
                  flow_start flow_end last_packet rx_packets tx_packets rx_bytes tx_bytes]

  # Attribution comes from the verified token (authoritative); the network
  # fields, flow window, and counters come from the body. Taking the body fields
  # as an explicit whitelist means a record can never supply its own attribution
  # (account, either endpoint device, role, policy, resource, actor) or the
  # server-assigned log_id, regardless of what keys it sends. Both endpoint
  # devices come from the token, so the two rows of a flow name the same pair
  # and only `role` says which side wrote which.
  defp to_attrs(record, claims, now) do
    record
    |> Map.take(@body_fields)
    |> Map.merge(%{
      "account_id" => claims["account_id"],
      "log_id" => LogId.build_flow_log(),
      "initiator_device_id" => claims["initiator_device_id"],
      "responder_device_id" => claims["responder_device_id"],
      "role" => claims["role"],
      "policy_authorization_id" => claims["policy_authorization_id"],
      "policy_id" => claims["policy_id"],
      "resource_id" => claims["resource_id"],
      "resource_name" => claims["resource_name"],
      "resource_address" => claims["resource_address"],
      "authorized_at" => claims["authorized_at"],
      "authorization_expires_at" => claims["authorization_expires_at"],
      "initiator_actor_id" => claims["initiator_actor_id"],
      "initiator_actor_email" => claims["initiator_actor_email"],
      "initiator_actor_name" => claims["initiator_actor_name"],
      "initiator_auth_provider_id" => claims["initiator_auth_provider_id"],
      "initiator_client_version" => claims["initiator_client_version"],
      "initiator_device_os_name" => claims["initiator_device_os_name"],
      "initiator_device_os_version" => claims["initiator_device_os_version"],
      "initiator_device_serial" => claims["initiator_device_serial"],
      "initiator_device_uuid" => claims["initiator_device_uuid"],
      "initiator_device_identifier_for_vendor" =>
        claims["initiator_device_identifier_for_vendor"],
      "initiator_device_firebase_installation_id" =>
        claims["initiator_device_firebase_installation_id"],
      "inserted_at" => now
    })
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.FlowLog
    alias Portal.Safe

    @identity_columns [
      :account_id,
      :initiator_device_id,
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
    # The attribution snapshot, inner tunnel tuple, and domain are stable for the
    # life of a flow and are only ever set on insert. A close replaces `outers`
    # because it may contain paths accumulated after an older open report.
    defp on_conflict_query do
      # The close takes a fresh seq so cursor-based consumers that already
      # delivered the open row see it again and deliver the close; start_seq
      # records the open-state seq so they can tell whether they did.
      from(f in FlowLog,
        update: [
          set: [
            seq: fragment("nextval('flow_logs_seq_seq')"),
            start_seq: f.seq,
            outers: fragment("EXCLUDED.outers"),
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
      {e.account_id, e.initiator_device_id, e.role, e.flow_start, e.protocol, e.inner_src_ip,
       e.inner_src_port, e.inner_dst_ip, e.inner_dst_port, e.resource_id}
    end
  end
end
