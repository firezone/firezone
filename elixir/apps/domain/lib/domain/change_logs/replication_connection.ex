defmodule Domain.ChangeLogs.ReplicationConnection do
  alias Domain.ChangeLogs

  use Domain.Replication.Connection,
    # Allow up to 30 seconds of lag before alerting
    alert_threshold_ms: 30_000,
    publication_name: "change_logs"

  # Bump this to signify a change in the audit log schema. Use with care.
  @vsn 0

  def on_insert(table, data) do
    log(:insert, table, nil, data)
  end

  def on_update(table, old_data, data) do
    log(:update, table, old_data, data)
  end

  def on_delete(table, old_data) do
    log(:delete, table, old_data, nil)
  end

  defp log(_op, "flows", _old_data, _data) do
    # TODO: WAL
    # Flows are not logged to the change log as they are used only to trigger side effects which
    # will be removed. Remove the flows table publication when that happens.
    :ok
  end

  defp log(op, table, old_data, data) do
    attrs = %{
      op: op,
      table: table,
      old_data: old_data,
      data: data,
      vsn: @vsn
    }

    case ChangeLogs.create_change_log(attrs) do
      {:ok, _change_log} ->
        :ok

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if foreign_key_error?(errors) do
          # Expected under normal operation when an account is deleted
          :ok
        else
          Logger.error("Failed to create change log", changeset: inspect(changeset))

          :error
        end
    end
  end

  defp foreign_key_error?(errors) do
    Enum.any?(errors, fn {field, {message, _}} ->
      field == :account_id and message == "does not exist"
    end)
  end
end
