defmodule Portal.Repo.Migrations.SwapChangeLogsCommittedAtIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(index(:change_logs, [:committed_at], concurrently: true))

    drop_if_exists(index(:change_logs, [:inserted_at], concurrently: true))
  end

  def down do
    create_if_not_exists(index(:change_logs, [:inserted_at], concurrently: true))

    drop_if_exists(index(:change_logs, [:committed_at], concurrently: true))
  end
end
