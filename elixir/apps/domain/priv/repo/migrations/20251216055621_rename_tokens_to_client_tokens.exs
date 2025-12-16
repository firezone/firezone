defmodule Domain.Repo.Migrations.RenameTokensToClientTokens do
  use Ecto.Migration

  def up do
    rename(table(:tokens), to: table(:client_tokens))

    alter table(:client_tokens) do
      remove(:type)
      remove(:name)
    end

    execute("DROP INDEX IF EXISTS tokens_account_id_id_index CASCADE")

    execute("ALTER TABLE client_tokens DROP CONSTRAINT IF EXISTS tokens_pkey;")

    execute("""
      ALTER TABLE client_tokens
      ADD CONSTRAINT client_tokens_pkey PRIMARY KEY (account_id, id)
    """)

    execute("""
      ALTER TABLE client_tokens
      ALTER COLUMN account_id SET NOT NULL
    """)

    execute("""
      ALTER TABLE client_tokens
      ALTER COLUMN actor_id SET NOT NULL
    """)

    execute("""
      ALTER TABLE client_tokens
      ALTER COLUMN expires_at SET NOT NULL
    """)

    execute("""
      ALTER TABLE policy_authorizations
      ADD CONSTRAINT policy_authorizations_token_id_fkey
      FOREIGN KEY (account_id, token_id) REFERENCES client_tokens(account_id, id) ON DELETE CASCADE
    """)
  end

  def down do
    # Irreversible migration
  end
end
