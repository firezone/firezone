defmodule Domain.Repo.Migrations.CreateOktaAuthProviders do
  use Domain, :migration

  def change do
    create table(:okta_auth_providers, primary_key: false) do
      account(primary_key: true)
      add(:auth_provider_id, :binary_id, null: false, primary_key: true)

      add(:context, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)
      add(:org_domain, :string, null: false)
      add(:client_id, :string, null: false)
      add(:client_secret, :string, null: false)

      subject_trail()
      timestamps()
    end

    create(index(:okta_auth_providers, [:account_id, :issuer], unique: true))
    create(index(:okta_auth_providers, [:account_id, :name], unique: true))

    execute(
      """
      ALTER TABLE okta_auth_providers
      ADD CONSTRAINT okta_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, auth_provider_id)
      REFERENCES auth_providers(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE okta_auth_providers
      DROP CONSTRAINT okta_auth_providers_auth_provider_id_fkey
      """
    )

    create(
      constraint(:okta_auth_providers, :context_must_be_valid,
        check: "context IN ('clients_and_portal', 'clients_only', 'portal_only')"
      )
    )
  end
end
