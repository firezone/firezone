defmodule Portal.Repo.Migrations.DropChangeLogsAccountIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Redundant with the (account_id, id) primary-key index.
  def up do
    drop_if_exists(index(:change_logs, [:account_id], concurrently: true))
  end

  def down do
    create_if_not_exists(index(:change_logs, [:account_id], concurrently: true))
  end
end
