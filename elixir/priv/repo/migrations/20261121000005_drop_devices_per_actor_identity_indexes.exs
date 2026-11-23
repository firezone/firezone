defmodule Portal.Repo.Migrations.DropDevicesPerActorIdentityIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :firezone_id],
        name: :devices_account_id_actor_id_firezone_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :last_attested_mdm_device_id],
        name: :devices_account_id_actor_id_last_attested_mdm_device_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial, :actor_id],
        name: :devices_account_id_cert_issuer_serial_actor_id_index,
        concurrently: true
      )
    )
  end

  def down, do: :ok
end
