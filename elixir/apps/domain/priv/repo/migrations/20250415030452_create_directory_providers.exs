defmodule Domain.Repo.Migrations.CreateDirectoryProviders do
  use Ecto.Migration

  def change do
    create table(:directory_providers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:type, :string, null: false)

      add(:sync_state, :map, default: %{}, null: false)

      # Config must be provided
      add(:config, :map, default: nil, null: false)

      add(:disabled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:directory_providers, [:account_id, :type], unique: true))
  end
end
