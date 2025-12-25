defmodule Portal.Repo.Migrations.RecreateActorsAccountIdIndex do
  use Ecto.Migration

  def change do
    execute("""
    DROP INDEX actors_account_id_index;
    """)

    execute("""
    CREATE INDEX clients_account_id_index
    ON clients (account_id)
    WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX actors_account_id_index
    ON actors (account_id)
    WHERE deleted_at IS NULL
    """)
  end
end
