defmodule Portal.Repo.Migrations.RenameAuthIdentitiesToExternalIdentities do
  use Ecto.Migration

  def up do
    # Rename the table
    rename(table(:auth_identities), to: table(:external_identities))

    # Rename the primary key constraint
    execute("ALTER INDEX auth_identities_pkey RENAME TO external_identities_pkey")

    # Rename the actor_id index
    execute(
      "ALTER INDEX auth_identities_actor_id_index RENAME TO external_identities_actor_id_index"
    )

    # Rename the foreign key constraints
    execute("""
    ALTER TABLE external_identities
    RENAME CONSTRAINT auth_identities_account_id_fkey TO external_identities_account_id_fkey
    """)

    execute("""
    ALTER TABLE external_identities
    RENAME CONSTRAINT auth_identities_actor_id_fkey TO external_identities_actor_id_fkey
    """)
  end

  def down do
    # Rename the foreign key constraints back
    execute("""
    ALTER TABLE external_identities
    RENAME CONSTRAINT external_identities_actor_id_fkey TO auth_identities_actor_id_fkey
    """)

    execute("""
    ALTER TABLE external_identities
    RENAME CONSTRAINT external_identities_account_id_fkey TO auth_identities_account_id_fkey
    """)

    # Rename the actor_id index back
    execute(
      "ALTER INDEX external_identities_actor_id_index RENAME TO auth_identities_actor_id_index"
    )

    # Rename the primary key constraint back
    execute("ALTER INDEX external_identities_pkey RENAME TO auth_identities_pkey")

    # Rename the table back
    rename(table(:external_identities), to: table(:auth_identities))
  end
end
