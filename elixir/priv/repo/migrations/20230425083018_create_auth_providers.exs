defmodule Portal.Repo.Migrations.CreateAuthProviders do
  use Ecto.Migration

  def change do
    create table(:auth_providers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:name, :string, null: false)

      add(:adapter, :string, null: false)
      add(:adapter_config, :map, default: %{}, null: false)

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:disabled_at, :utc_datetime_usec)
      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:auth_providers, [:account_id], where: "deleted_at IS NULL"))
  end
end
