defmodule Portal.Repo.Migrations.CreateEntraAuthProviders do
  use Ecto.Migration

  def change do
    create table(:entra_auth_providers, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:context, :string, null: false)
      add(:client_session_lifetime_secs, :integer)
      add(:portal_session_lifetime_secs, :integer)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:is_default, :boolean, default: false, null: false)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)

      add(:created_by, :string, null: false)
      add(:created_by_subject, :map)
      timestamps()
    end

    create(
      index(:entra_auth_providers, [:account_id, :issuer],
        name: :entra_auth_providers_account_id_issuer_index,
        unique: true
      )
    )

    create(
      index(:entra_auth_providers, [:account_id, :name],
        name: :entra_auth_providers_account_id_name_index,
        unique: true
      )
    )

    execute(
      """
      ALTER TABLE entra_auth_providers
      ADD CONSTRAINT entra_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, id)
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
