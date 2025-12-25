defmodule Portal.Repo.Migrations.IndexFlowsOnTokenId do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS flows_account_id_token_id_index ON flows USING BTREE (account_id, token_id, inserted_at DESC, id DESC);
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS flows_account_id_token_id_index;
    """)
  end
end
