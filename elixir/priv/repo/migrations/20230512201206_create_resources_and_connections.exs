defmodule Portal.Repo.Migrations.CreateResourcesAndConnections do
  use Ecto.Migration

  def change do
    create table(:resources, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:address, :string, null: false)
      add(:name, :string, null: false)

      add(:filters, :map, default: fragment("'[]'::jsonb"), null: false)

      add(
        :ipv4,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id]
        )
      )

      add(
        :ipv6,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id]
        )
      )

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:resources, [:account_id, :ipv4], unique: true, where: "deleted_at IS NULL"))
    create(index(:resources, [:account_id, :ipv6], unique: true, where: "deleted_at IS NULL"))

    create(
      index(:resources, [:account_id, :name],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    create(
      index(:resources, [:account_id, :address],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    create table(:resource_connections, primary_key: false) do
      add(:resource_id, references(:resources, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(
        :gateway_group_id,
        references(:gateway_groups, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:account_id, references(:accounts, type: :binary_id), null: false)
    end
  end
end
