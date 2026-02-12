defmodule Portal.Repo.Migrations.RenameClientSessionsInsertedAtIndex do
  use Ecto.Migration

  def change do
    execute(
      "ALTER INDEX client_sessions_account_id_inserted_at_index RENAME TO client_sessions_inserted_at_index",
      "ALTER INDEX client_sessions_inserted_at_index RENAME TO client_sessions_account_id_inserted_at_index"
    )
  end
end
