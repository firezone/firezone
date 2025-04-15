defmodule Domain.Repo.Migrations.CreateDirectoryProviders do
  use Ecto.Migration

  def change do
    create table(:directory_providers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id), null: false)
      add(:auth_provider_id, references(:auth_providers, type: :binary_id), null: false)

      add(:type, :string, null: false)

      add(:sync_state, :map, default: %{}, null: false)

      add(:disabled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:directory_providers, [:account_id, :auth_provider_id], unique: true))
  end
end
