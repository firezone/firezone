defmodule PortalAPI.FlowLogController do
  use PortalAPI, :controller
  import Ecto.Changeset
  alias Portal.FlowLog
  alias PortalAPI.ProblemDetails
  alias __MODULE__.Database

  @top_level_keys ~w(flow_id device_id role flow_start flow_end)
  @cast_fields ~w[flow_id account_id device_id role flow_start flow_end payload inserted_at]a
  @max_batch_size 10_000

  def create(conn, %{"flow_logs" => records})
      when is_list(records) and length(records) > @max_batch_size do
    ProblemDetails.send(conn, 400, "Batch size exceeds maximum of #{@max_batch_size}")
  end

  def create(conn, %{"flow_logs" => records}) when is_list(records) do
    account_id = conn.assigns.account.id
    now = DateTime.utc_now()

    {entries, errors} =
      records
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {record, index}, acc ->
        validate_record(record, index, account_id, now, acc)
      end)

    if entries != [] do
      Database.insert_all_flow_logs(entries)
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

  defp validate_record(record, index, _account_id, _now, {valid, invalid})
       when not is_map(record) do
    {valid, [{index, :not_a_map} | invalid]}
  end

  defp validate_record(record, index, account_id, now, {valid, invalid}) do
    changeset =
      record
      |> to_attrs(account_id, now)
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

  defp to_attrs(record, account_id, now) do
    {top, rest} = Map.split(record, @top_level_keys)

    %{
      "flow_id" => top["flow_id"],
      "account_id" => account_id,
      "device_id" => top["device_id"],
      "role" => top["role"],
      "flow_start" => top["flow_start"],
      "flow_end" => top["flow_end"],
      "payload" => rest,
      "inserted_at" => now
    }
  end

  defmodule Database do
    alias Portal.Safe
    alias Portal.FlowLog

    def insert_all_flow_logs(entries) do
      Safe.unscoped()
      |> Safe.insert_all(FlowLog, entries, on_conflict: :nothing)
    end
  end
end
