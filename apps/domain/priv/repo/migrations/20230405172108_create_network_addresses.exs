defmodule Domain.Repo.Migrations.CreateNetworkAddresses do
  use Ecto.Migration

  def change do
    create(table(:network_addresses, primary_key: false)) do
      add(:type, :string, null: false)
      add(:address, :inet, null: false, primary_key: true)
    end
  end
end
