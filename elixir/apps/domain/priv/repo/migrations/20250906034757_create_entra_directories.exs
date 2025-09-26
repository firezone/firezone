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

      add(:client_id, :string, null: false)
      add(:client_secret, :string, null: false)
      add(:tenant_id, :string, null: false)

      add(:last_error, :text)
      add(:error_emailed_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)

      timestamps()
    end

    # 2: Add separate indexes to handle preloads and cascading deletes
    create(index(:entra_directories, :account_id))
    create(index(:entra_directories, :auth_provider_id))
  end
end
