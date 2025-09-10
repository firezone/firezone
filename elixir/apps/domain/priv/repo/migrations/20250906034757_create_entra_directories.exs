defmodule Domain.Repo.Migrations.CreateEntraDirectories do
  use Ecto.Migration

  def change do
    # 1: Create table
    create table(:entra_directories, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :auth_provider_id,
        references(:auth_providers, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, :string, null: false)

      add(:groups_delta_link, :string)
      add(:users_delta_link, :string)

      add(:last_error, :string)
      add(:error_emailed_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)

      timestamps()
    end

    # 2: Add indexes
    create(index(:entra_directories, [:account_id, :auth_provider_id]))

    # 3. Populate from existing auth_providers
    execute(
      """
        INSERT INTO entra_directories (id, account_id, auth_provider_id, tenant_id, inserted_at, updated_at)
        SELECT gen_random_uuid(), account_id, id,
        (regexp_match(adapter_config->>'discovery_document_uri', 'login\.microsoftonline\.com/([a-f0-9\-]{36})'))[1],
          NOW(), NOW()
        FROM auth_providers
        WHERE adapter = 'microsoft_entra'
      """,
      # down is a no-op
      ""
    )
  end
end
