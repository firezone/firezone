defmodule Portal.Repo.Migrations.RemoveSoftDeletedData do
  use Ecto.Migration

  def up do
    # Delete all soft-deleted records from tables that have deleted_at column
    # This is a data cleanup migration before removing the soft delete functionality

    # The order of execution was chosen to try and minimize ON DELETE CASCADE deletions

    execute("""
    DELETE FROM tokens WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM resources WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM auth_identities WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM clients WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM gateways WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM actors WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM actor_groups WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM auth_providers WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM gateway_groups WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM policies WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM relays WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM relay_groups WHERE deleted_at IS NOT NULL
    """)

    execute("""
    DELETE FROM accounts WHERE deleted_at IS NOT NULL
    """)
  end

  def down do
    # no-op Deleted data cannot be restored
  end
end
