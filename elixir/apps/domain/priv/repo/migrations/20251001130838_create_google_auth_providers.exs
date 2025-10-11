defmodule Domain.Repo.Migrations.CreateGoogleAuthProviders do
  use Domain, :migration

  def change do
    create table(:google_auth_providers, primary_key: false) do
      account(primary_key: true)
      add(:auth_provider_id, :binary_id, null: false, primary_key: true)

      add(:context, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)
      add(:hosted_domain, :string)

      subject_trail()
      timestamps()
    end

    create(index(:google_auth_providers, [:account_id, :issuer, :hosted_domain], unique: true))
    create(index(:google_auth_providers, [:account_id, :name], unique: true))

    execute(
      """
      ALTER TABLE google_auth_providers
      ADD CONSTRAINT google_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, auth_provider_id)
      REFERENCES auth_providers(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE google_auth_providers
      DROP CONSTRAINT google_auth_providers_auth_provider_id_fkey
      """
    )

    create(
      constraint(:google_auth_providers, :context_must_be_valid,
        check: "context IN ('clients_and_portal', 'clients_only', 'portal_only')"
      )
    )
  end
end
