defmodule Domain.ChangeLogs.ReplicationConnection do
  alias Domain.ChangeLogs

  use Domain.Replication.Connection,
    # Allow up to 5 minutes of processing lag before alerting. This needs to be able to survive
    # deploys without alerting.
    warning_threshold_ms: 5 * 60 * 1_000,

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
        if Enum.any?(errors, &should_skip_change_log?/1) do
          # Expected under normal operation when an account is deleted or we are catching up on
          # already-processed but not acknowledged WAL data.
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

  defp should_skip_change_log?({:account_id, {"does not exist", _violations}}) do
    true
  end

  defp should_skip_change_log?({:lsn, {"has already been taken", _violations}}) do
    true
  end

  defp should_skip_change_log?(_error) do
    false
  end
end
