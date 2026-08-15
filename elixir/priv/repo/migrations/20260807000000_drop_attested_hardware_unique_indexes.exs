defmodule Portal.Repo.Migrations.DropAttestedHardwareUniqueIndexes do
  @moduledoc """
  Leaves the MDM device id as the only unique attested identifier.

  The hardware serial and UUID were unique per actor so a device whose MDM
  record changed could be relocated by them. Microsoft documents those values
  as spoofable by anyone with access to the device (they are self-reported at
  enrollment and the MDM merely repeats them), so resolving identity by them
  was weaker than the certificate's service-assigned MDM device id. They stay
  on the row as attributes and are checked for contradiction at connect, but
  they no longer identify anything and so no longer need a unique index.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :last_attested_device_serial],
        name: :devices_account_id_actor_id_last_attested_device_serial_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :last_attested_device_uuid],
        name: :devices_account_id_actor_id_last_attested_device_uuid_index,
        concurrently: true
      )
    )
  end

  def down do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :last_attested_device_serial],
        where: "last_attested_device_serial IS NOT NULL",
        name: :devices_account_id_actor_id_last_attested_device_serial_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :last_attested_device_uuid],
        where: "last_attested_device_uuid IS NOT NULL",
        name: :devices_account_id_actor_id_last_attested_device_uuid_index,
        concurrently: true
      )
    )
  end
end
