defmodule Domain.ChangeLogs.ReplicationConnection do
  use Domain.Replication.Connection
  alias Domain.ChangeLogs

  # Bump this to signify a change in the audit log schema. Use with care.
  @vsn 0

  # Ignore token writes for relay_groups since these are not expected to have an account_id
  def on_write(state, _lsn, _op, "tokens", %{"type" => "relay_group"}, _data), do: state
  def on_write(state, _lsn, _op, "tokens", _old_data, %{"type" => "relay_group"}), do: state

  # Handle accounts specially
  def on_write(state, lsn, op, "accounts", %{"id" => account_id} = old_data, data) do
    buffer(state, lsn, op, "accounts", account_id, old_data, data)
  end

  def on_write(state, lsn, op, "accounts", old_data, %{"id" => account_id} = data) do
    buffer(state, lsn, op, "accounts", account_id, old_data, data)
  end

  # Handle other writes where an account_id is present
  def on_write(state, lsn, op, table, old_data, %{"account_id" => account_id} = data)
      when not is_nil(account_id) do
    buffer(state, lsn, op, table, account_id, old_data, data)
  end

  def on_write(state, lsn, op, table, %{"account_id" => account_id} = old_data, data)
      when not is_nil(account_id) do
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

    {successful_count, _change_logs} = ChangeLogs.bulk_insert(to_insert)

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

  defp buffer(state, lsn, op, table, account_id, old_data, data) do
    flush_buffer =
      state.flush_buffer
      |> Map.put_new(lsn, %{
        lsn: lsn,
        op: op,
        table: table,
        account_id: account_id,
        old_data: old_data,
        data: data,
        vsn: @vsn
      })

    %{state | flush_buffer: flush_buffer}
  end
end
