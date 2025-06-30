defmodule Domain.ChangeLogs.ReplicationConnection do
  use Domain.Replication.Connection
  alias Domain.ChangeLogs

  # Bump this to signify a change in the audit log schema. Use with care.
  @vsn 0

  def on_insert(lsn, table, data, state) do
    attrs = %{
      lsn: lsn,
      table: table,
      op: :insert,
      data: data,
      old_data: nil,
      vsn: @vsn
    }

    %{state | flush_buffer: [attrs | state.flush_buffer]}
  end

  def on_update(lsn, table, old_data, data, state) do
    attrs = %{
      lsn: lsn,
      table: table,
      op: :update,
      data: data,
      old_data: old_data,
      vsn: @vsn
    }

    %{state | flush_buffer: [attrs | state.flush_buffer]}
  end

  def on_delete(lsn, table, old_data, state) do
    # Avoid overwhelming the change log with soft-deleted records getting hard-deleted en masse.
    # Can be removed after https://github.com/firezone/firezone/issues/8187 is shipped.
    if is_nil(old_data["deleted_at"]) do
      attrs = %{
        lsn: lsn,
        table: table,
        op: :delete,
        data: nil,
        old_data: old_data,
        vsn: @vsn
      }

      %{state | flush_buffer: [attrs | state.flush_buffer]}
    else
      state
    end
  end

  def on_flush(%{flush_buffer: []} = state), do: state

  def on_flush(state) do
    {count, change_logs} = ChangeLogs.bulk_insert(state.flush_buffer)

    if count < length(state.flush_buffer) do
      Logger.info("Failed to insert some change logs",
        attempted: length(state.flush_buffer),
        successful: count,
        successful_lsns: Enum.map(change_logs, & &1.lsn)
      )
    else
      Logger.debug("Inserted change logs",
        count: count,
        successful_lsns: Enum.map(change_logs, & &1.lsn)
      )
    end

    last_flushed_lsn = last_flushed_lsn(state.flush_buffer, change_logs)

    %{
      state
      | flush_buffer: [],
        last_flushed_lsn: last_flushed_lsn
    }
  rescue
    Postgrex.Error ->
      Logger.warning("Failed to insert change logs",
        attempted: length(state.flush_buffer)
      )

      %{state | flush_buffer: []}
  end

  # Get the last LSN that was successfully flushed.
  defp last_flushed_lsn(buffer, successful) do
    buffer_lsns = Enum.map(buffer, & &1.lsn)
    successful_lsns = Enum.map(successful, & &1.lsn)

    diff_lsns = buffer_lsns -- successful_lsns

    if diff_lsns == [] do
      buffer_lsns |> Enum.sort() |> List.last()
    else
      first_missing = diff_lsns |> Enum.sort() |> List.first()

      last_successful_index =
        (buffer_lsns |> Enum.sort() |> Enum.find_index(&(&1 == first_missing))) - 1

      last_successful_index =
        if last_successful_index < 0 do
          0
        else
          last_successful_index
        end

      Enum.at(buffer_lsns, last_successful_index)
    end
  end
end
