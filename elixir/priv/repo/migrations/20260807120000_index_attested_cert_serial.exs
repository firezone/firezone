defmodule Portal.Repo.Migrations.IndexAttestedCertSerial do
  @moduledoc """
  Indexes the pinned certificate serial so it can act as a fallback identity.

  Not every MDM can assert a device id: Mosyle offers only a serial number
  variable, so certificates from it carry no MDM device id at all. Those
  connects fall back to matching the pinned certificate, which needs an index
  to avoid a sequential scan over `devices` on every connect.

  Unique where non-NULL, so one certificate can only ever stand for one
  device. Two anchors in the same account issuing the same serial is the only
  way to collide, and refusing the second is the correct outcome: nothing
  could say which device is connecting.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :last_attested_cert_serial],
        where: "last_attested_cert_serial IS NOT NULL",
        name: :devices_account_id_actor_id_last_attested_cert_serial_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :last_attested_cert_serial],
        name: :devices_account_id_actor_id_last_attested_cert_serial_index,
        concurrently: true
      )
    )
  end
end
