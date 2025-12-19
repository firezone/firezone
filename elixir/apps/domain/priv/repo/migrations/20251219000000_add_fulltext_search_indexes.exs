defmodule Domain.Repo.Migrations.AddFulltextSearchIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Enable pg_trgm extension for trigram indexes (needed for ILIKE optimization)
    execute(
      "CREATE EXTENSION IF NOT EXISTS pg_trgm",
      "DROP EXTENSION IF EXISTS pg_trgm"
    )

    # Create an immutable wrapper for unaccent (required for index expressions)
    execute(
      """
      CREATE OR REPLACE FUNCTION immutable_unaccent(text)
      RETURNS text AS $$
        SELECT public.unaccent($1)
      $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
      """,
      "DROP FUNCTION IF EXISTS immutable_unaccent(text)"
    )

    # Resources indexes
    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_name_trigram_idx
      ON resources USING gin(immutable_unaccent(name) gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS resources_name_trigram_idx"
    )

    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_address_trigram_idx
      ON resources USING gin(immutable_unaccent(address) gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS resources_address_trigram_idx"
    )

    # Actors indexes
    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS actors_name_trigram_idx
      ON actors USING gin(immutable_unaccent(name) gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS actors_name_trigram_idx"
    )

    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS actors_email_trigram_idx
      ON actors USING gin(immutable_unaccent(email) gin_trgm_ops)
      WHERE email IS NOT NULL
      """,
      "DROP INDEX IF EXISTS actors_email_trigram_idx"
    )

    # Clients indexes
    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS clients_name_trigram_idx
      ON clients USING gin(immutable_unaccent(name) gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS clients_name_trigram_idx"
    )

    # Groups indexes
    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS groups_name_trigram_idx
      ON groups USING gin(immutable_unaccent(name) gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS groups_name_trigram_idx"
    )
  end
end
