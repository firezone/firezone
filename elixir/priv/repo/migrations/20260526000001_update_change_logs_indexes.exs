defmodule Portal.Repo.Migrations.UpdateChangeLogsIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  # The standalone account_id index is redundant with the new
  # (account_id, event_id) primary-key index.
  def up do
    drop_if_exists(index(:change_logs, [:account_id], concurrently: true))
  end

  def down do
    create_if_not_exists(index(:change_logs, [:account_id], concurrently: true))
  end
end
