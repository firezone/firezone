defmodule Domain.Repo.Migrations.CreateEntraProviders do
  use Ecto.Migration

  def change do
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

      add(:users_delta_link, :string)
      add(:groups_delta_link, :string)
      add(:error_count, :integer, default: 0, null: false)
      add(:last_error, :string)
      add(:error_emailed_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:group_filtering_enabled_at, :utc_datetime_usec)

      timestamps()
    end

    create(index(:entra_directories, [:account_id, :auth_provider_id]))

    create table(:entra_group_inclusions, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :entra_directory_id,
        references(:entra_directories, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:external_id, :string, null: false, primary_key: true)

      timestamps(updated_at: false)
    end
  end
end
