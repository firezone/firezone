defmodule Domain.Repo.Migrations.CreateUserpassAuthProviders do
  use Domain, :migration

  def change do
    create table(:userpass_auth_providers, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      account()

      add(:name, :string, null: false)
      add(:issuer, :text, null: false, default: "firezone")
      add(:context, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:userpass_auth_providers, [:account_id], unique: true))

    execute(
      """
      ALTER TABLE userpass_auth_providers
      ADD CONSTRAINT userpass_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, id)
      REFERENCES auth_providers(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE userpass_auth_providers
      DROP CONSTRAINT userpass_auth_providers_auth_provider_id_fkey
      """
    )

    create(
      constraint(:userpass_auth_providers, :context_must_be_valid,
        check: "context IN ('clients_and_portal', 'clients_only', 'portal_only')"
      )
    )

    create(
      constraint(:userpass_auth_providers, :issuer_must_be_firezone, check: "issuer = 'firezone'")
    )
  end
end
