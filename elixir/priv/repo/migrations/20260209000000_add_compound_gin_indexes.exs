defmodule Portal.Repo.Migrations.AddCompoundGinIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gin")

    # Actors
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS actors_account_name_trigram_idx
    ON actors USING gin(account_id, immutable_unaccent(name) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS actors_account_email_trigram_idx
    ON actors USING gin(account_id, immutable_unaccent(email) gin_trgm_ops)
    WHERE email IS NOT NULL
    """)

    # Clients
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS clients_account_name_trigram_idx
    ON clients USING gin(account_id, immutable_unaccent(name) gin_trgm_ops)
    """)

    # Groups
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS groups_account_name_trigram_idx
    ON groups USING gin(account_id, immutable_unaccent(name) gin_trgm_ops)
    """)

    # Resources
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_account_name_trigram_idx
    ON resources USING gin(account_id, immutable_unaccent(name) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_account_address_trigram_idx
    ON resources USING gin(account_id, immutable_unaccent(address) gin_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS resources_account_address_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS resources_account_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS groups_account_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS clients_account_name_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS actors_account_email_trigram_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS actors_account_name_trigram_idx")
  end
end
