defmodule Portal.Repo.Migrations.AddDevicesKeyIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Rows with a key are found by the key, so only rows without one need a unique firezone_id.
  def up do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :key_hash],
        where: "key_hash IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "type = 'client' AND key_hash IS NULL",
        name: :devices_account_id_unkeyed_client_firezone_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "type = 'gateway' AND key_hash IS NULL AND NOT firezone_id_exempt",
        name: :devices_account_id_unkeyed_gateway_firezone_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :firezone_id],
        name: :devices_account_id_client_firezone_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :firezone_id],
        name: :devices_account_id_firezone_id_index,
        concurrently: true
      )
    )
  end

  def down do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "type = 'client'",
        name: :devices_account_id_client_firezone_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "type = 'gateway' AND NOT firezone_id_exempt",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :firezone_id],
        name: :devices_account_id_unkeyed_gateway_firezone_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :firezone_id],
        name: :devices_account_id_unkeyed_client_firezone_id_index,
        concurrently: true
      )
    )

    drop_if_exists(index(:devices, [:account_id, :key_hash], concurrently: true))
  end
end
