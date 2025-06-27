defmodule Domain.ChangeLogs.ReplicationConnection do
  alias Domain.ChangeLogs

  use Domain.Replication.Connection,
    # Allow up to 30 seconds of processing lag before alerting - this should be less
    # than or equal to the wal_sender_timeout setting, which is typically 60s.
    warning_threshold_ms: 30 * 1_000,

    # 1 month in ms - we never want to bypass changelog inserts
    error_threshold_ms: 30 * 24 * 60 * 60 * 1_000

  # Bump this to signify a change in the audit log schema. Use with care.
  @vsn 0

  def on_insert(lsn, table, data) do
    log(:insert, lsn, table, nil, data)
  end

  def on_update(lsn, table, old_data, data) do
    log(:update, lsn, table, old_data, data)
  end

  def on_delete(lsn, table, old_data) do
    if is_nil(old_data["deleted_at"]) do
      log(:delete, lsn, table, old_data, nil)
    else
      # Avoid overwhelming the change log with soft-deleted records getting hard-deleted en masse.
      # Can be removed after https://github.com/firezone/firezone/issues/8187 is shipped.
      :ok
    end
  end

  # Relay group tokens don't have account_ids

  defp log(_op, _lsn, "tokens", %{"type" => "relay_group"}, _data) do
    :ok
  end

  defp log(_op, _lsn, "tokens", _old_data, %{"type" => "relay_group"}) do
    :ok
  end

  defp log(_op, _lsn, "flows", _old_data, _data) do
    # TODO: WAL
    # Flows are not logged to the change log as they are used only to trigger side effects which
    # will be removed. Remove the flows table publication when that happens.
    :ok
  end

  defp log(op, lsn, table, old_data, data) do
    attrs = %{
      op: op,
      lsn: lsn,
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
          Logger.warning("Failed to create change log",
            errors: inspect(changeset.errors),
            table: table,
            op: op,
            lsn: lsn,
            vsn: @vsn
          )

          # TODO: WAL
          # Don't ignore failures to insert change logs. Improve this after we have some
          # operational experience with the data flowing in here.
          :ok
        end
    end
  end

  defp foreign_key_error?(errors) do
    Enum.any?(errors, fn {field, {message, _}} ->
      field == :account_id and message == "does not exist"
    end)
  end
end
