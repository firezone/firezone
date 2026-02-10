defmodule Portal.Repo.Migrations.DropOldTrigramIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS actors_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS actors_email_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS clients_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS groups_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS resources_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS resources_address_trigram_idx")
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS actors_name_trigram_idx
    ON actors USING gin(immutable_unaccent(name) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS actors_email_trigram_idx
    ON actors USING gin(immutable_unaccent(email) gin_trgm_ops)
    WHERE email IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS clients_name_trigram_idx
    ON clients USING gin(immutable_unaccent(name) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS groups_name_trigram_idx
    ON groups USING gin(immutable_unaccent(name) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_name_trigram_idx
    ON resources USING gin(immutable_unaccent(name) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_address_trigram_idx
    ON resources USING gin(immutable_unaccent(address) gin_trgm_ops)
    """)
  end
end
