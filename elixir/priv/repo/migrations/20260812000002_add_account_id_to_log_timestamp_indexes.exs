defmodule Portal.Repo.Migrations.AddAccountIdToLogTimestampIndexes do
  @moduledoc """
  Adds `account_id` to the global timestamp indexes used by log retention.

  Keeping the timestamp first preserves global retention scans, while the
  account id lets account-scoped log listings reject rows in the index before
  fetching their wide heap tuples.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @indexes [
    {:session_logs, :timestamp},
    {:change_logs, :timestamp},
    {:api_request_logs, :inserted_at}
  ]

  def up do
    for {table, timestamp} <- @indexes do
      create(index(table, [timestamp, :account_id], concurrently: true))
    end

    for {table, timestamp} <- @indexes do
      drop(index(table, [timestamp], concurrently: true))
    end
  end

  def down do
    for {table, timestamp} <- @indexes do
      create(index(table, [timestamp], concurrently: true))
    end

    for {table, timestamp} <- @indexes do
      drop(index(table, [timestamp, :account_id], concurrently: true))
    end
  end
end
