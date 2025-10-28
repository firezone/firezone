defmodule Domain.Repo.Migrations.CreateGoogleAuthProviders do
  use Domain, :migration

  def change do
    create table(:google_auth_providers, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)
      account()

      add(:context, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)
      add(:verified_at, :utc_datetime_usec)
      add(:is_default, :boolean, default: false, null: false)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)
      add(:hosted_domain, :string)

      subject_trail()
      timestamps()
    end

    create(
      index(:google_auth_providers, [:account_id, :issuer, :hosted_domain],
        unique: true,
        # Allow only one null hosted_domain (i.e. personal GMail accounts) per account
        nulls_distinct: false
      )
    )

    create(index(:google_auth_providers, [:account_id, :name], unique: true))

    execute(
      """
      ALTER TABLE google_auth_providers
      ADD CONSTRAINT google_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, id)
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
