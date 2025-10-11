defmodule Domain.Repo.Migrations.AddAuthProviderIdToTokens do
  use Domain, :migration

  def change do
    alter table(:tokens) do
      add(:auth_provider_id, :binary_id, null: true)
    end

    execute(
      """
      ALTER TABLE tokens
      ADD CONSTRAINT tokens_auth_provider_id_fkey
      FOREIGN KEY (account_id, auth_provider_id)
      REFERENCES auth_providers(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE tokens
      DROP CONSTRAINT tokens_auth_provider_id_fkey
      """
    )
  end
end
