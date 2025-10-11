defmodule Domain.Repo.Migrations.CreateEntraAuthProviders do
  use Domain, :migration

  def change do
    create table(:entra_auth_providers, primary_key: false) do
      account(primary_key: true)
      add(:auth_provider_id, :binary_id, null: false, primary_key: true)

      add(:context, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)
      add(:tenant_id, :string, null: false)

      subject_trail()
      timestamps()
    end

    create(index(:entra_auth_providers, [:account_id, :issuer], unique: true))
    create(index(:entra_auth_providers, [:account_id, :name], unique: true))

    execute(
      """
      ALTER TABLE entra_auth_providers
      ADD CONSTRAINT entra_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, auth_provider_id)
      REFERENCES auth_providers(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE entra_auth_providers
      DROP CONSTRAINT entra_auth_providers_auth_provider_id_fkey
      """
    )

    create(
      constraint(:entra_auth_providers, :context_must_be_valid,
        check: "context IN ('clients_and_portal', 'clients_only', 'portal_only')"
      )
    )
  end
end
