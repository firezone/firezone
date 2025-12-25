defmodule Portal.Repo.Migrations.CreateNetworkAddresses do
  use Ecto.Migration

  def change do
    create(table(:network_addresses, primary_key: false)) do
      add(:type, :string, null: false)
      add(:address, :inet, null: false, primary_key: true)
      add(:account_id, references(:accounts, type: :binary_id), null: false, primary_key: true)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
