defmodule PortalAPI.FlowLogController do
  # This endpoint is intentionally omitted from the OpenAPI spec. It is not part
  # of the public REST API: it exists solely for Clients and Gateways to batch-post
  # their flow logs, and is not meant to be called by API consumers. That is why
  # this controller deliberately does not `use OpenApiSpex.ControllerSpecs` and
  # declares no `operation`/`request_body` specs (which is what would otherwise
  # cause `Paths.from_router/1` to document it).
  use PortalAPI, :controller
  import Ecto.Changeset
  alias Portal.FlowLog
  alias Portal.Types.EventId
  alias PortalAPI.ProblemDetails
  alias __MODULE__.Database
  require Logger

  @cast_fields ~w[account_id event_id device_id role protocol flow_start flow_end last_packet
                  auth_provider_id actor_id actor_name actor_email resource_id resource_name
                  resource_address inner_src_ip inner_dst_ip inner_src_port inner_dst_port
                  inner_domain outer_src_ip outer_dst_ip outer_src_port outer_dst_port
                  rx_packets tx_packets rx_bytes tx_bytes inserted_at]a
  @server_assigned_keys ~w[account_id event_id inserted_at]
  @max_batch_size 10_000

  def create(conn, %{"flow_logs" => records})
      when is_list(records) and length(records) > @max_batch_size do
    ProblemDetails.send(conn, 400, "Batch size exceeds maximum of #{@max_batch_size}")
  end

  def create(conn, %{"flow_logs" => records}) when is_list(records) do
    account_id = conn.assigns.account.id
    token_type = conn.assigns.token_type
    actor = conn.assigns.actor
    now = DateTime.utc_now()

    {entries, errors} =
      records
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {record, index}, acc ->
        validate_record(record, index, account_id, token_type, actor, now, acc)
      end)

    if entries != [] do
      {inserted, _} = Database.insert_all_flow_logs(entries)
      dropped = length(entries) - inserted

      # Dropped entries are duplicates by the flow uniqueness tuple
      # (flow_logs_unique_flow_per_window). Usually a benign batch retry, but
      # logged so sustained drops (clock regression, a cloned device identity)
      # are visible rather than silent data loss.
      if dropped > 0 do
        Logger.info("Deduplicated #{dropped} flow log entries",
          account_id: account_id,
          token_type: token_type
        )
      end
    end

    if errors == [] do
      conn
      |> put_status(202)
      |> put_view(json: PortalAPI.FlowLogJSON)
      |> render(:accepted)
    else
      validation_errors = render_validation_errors(Enum.reverse(errors))

      ProblemDetails.send(conn, 422, "Some flow log records failed validation", %{
        validation_errors: validation_errors
      })
    end
  end

  def create(conn, _params) do
    ProblemDetails.send(conn, 400, "Expected a \"flow_logs\" array")
  end

  defp validate_record(record, index, _account_id, _token_type, _actor, _now, {valid, invalid})
       when not is_map(record) do
    {valid, [{index, :not_a_map} | invalid]}
  end

  defp validate_record(record, index, account_id, token_type, actor, now, {valid, invalid}) do
    changeset =
      record
      |> to_attrs(account_id, token_type, actor, now)
      |> changeset()

    if changeset.valid? do
      entry = Map.new(@cast_fields, &{&1, get_field(changeset, &1)})
      {[entry | valid], invalid}
    else
      {valid, [{index, changeset} | invalid]}
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

      {index, changeset} ->
        {index, Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
    end)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp to_attrs(record, account_id, token_type, actor, now) do
    record
    |> Map.drop(@server_assigned_keys)
    |> force_gateway_role(token_type)
    |> force_initiator_actor(token_type, actor)
    |> Map.merge(%{
      "account_id" => account_id,
      "event_id" => EventId.build_flow_log(),
      "inserted_at" => now
    })
  end

  # A Gateway is always the responder side of a flow, so its role is forced
  # from the token type rather than trusted from the payload. Clients report
  # either role (client-client flows), validated by the changeset.
  defp force_gateway_role(record, :gateway), do: Map.put(record, "role", "responder")
  defp force_gateway_role(record, :client), do: record

  # The actor is always the initiating client. When a Client reports its own
  # initiator side, its identity is exactly the authenticated token's actor,
  # so we overwrite the actor fields from the token rather than trust the
  # payload: a Client cannot attribute its initiated flows to another actor.
  #
  # Responder rows are left untouched. There the actor describes the remote
  # initiator, which the reporter (a responding Client, or a Gateway with no
  # actor of its own) legitimately observed but cannot prove from its token.
  defp force_initiator_actor(%{"role" => "initiator"} = record, :client, %Portal.Actor{} = actor) do
    Map.merge(record, %{
      "actor_id" => actor.id,
      "actor_name" => actor.name,
      "actor_email" => actor.email
    })
  end

  defp force_initiator_actor(record, _token_type, _actor), do: record

  defmodule Database do
    alias Portal.Safe
    alias Portal.FlowLog

    def insert_all_flow_logs(entries) do
      Safe.unscoped()
      |> Safe.insert_all(FlowLog, entries, on_conflict: :nothing)
    end
  end
end
