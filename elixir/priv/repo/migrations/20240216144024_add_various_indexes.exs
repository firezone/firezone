defmodule Portal.Repo.Migrations.AddVariousIndexes do
  use Ecto.Migration

  def change do
    execute("""
    CREATE INDEX clients_account_id_last_seen_at_index
    ON clients (account_id, last_seen_at DESC)
    WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX actors_account_id_index
    ON clients (account_id)
    WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX actor_group_memberships_account_id_group_id_actor_id_index
    ON actor_group_memberships (account_id, group_id, actor_id)
    """)
  end
end
