defmodule Domain.Repo.Migrations.CreateDirectoryProviders do
  use Ecto.Migration

  def change do
    create table(:directory_providers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id), null: false)
      add(:auth_provider_id, references(:auth_providers, type: :binary_id), null: false)

      add(:sync_state, :map, default: %{}, null: false)

      # TODO: Add sync fields common to all directory providers here

      add(:disabled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:directory_providers, [:account_id, :auth_provider_id], unique: true))

    # Populate directory_providers with existing sync-enabled auth_providers
    execute("""
      INSERT INTO directory_providers (id, account_id, auth_provider_id, disabled_at, inserted_at, updated_at)
      SELECT gen_random_uuid(), auth_providers.account_id, auth_providers.id, auth_providers.sync_disabled_at, now(), now()
      FROM auth_providers
      WHERE auth_providers.adapter IN ('okta', 'google_workspace', 'microsoft_entra', 'jumpcloud')
      AND auth_providers.deleted_at IS NULL
    """)

    # Drop no longer needed columns from auth_providers
    alter table(:auth_providers) do
      remove(:sync_disabled_at)
      remove(:last_synced_at)
      remove(:last_sync_error)
      remove(:sync_error_emailed_at)
      remove(:last_syncs_failed)
    end
  end
end
