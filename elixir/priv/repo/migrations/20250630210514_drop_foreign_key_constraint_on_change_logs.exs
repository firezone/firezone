defmodule Portal.Repo.Migrations.DropForeignKeyConstraintOnChangeLogs do
  use Ecto.Migration

  def up do
    drop(constraint(:change_logs, :change_logs_account_id_fkey))
  end

  def down do
    alter table(:change_logs) do
      modify(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all))
    end
  end
end
