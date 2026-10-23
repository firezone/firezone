defmodule Portal.Repo.Migrations.DeviceIdentityWithoutActor do
  @moduledoc """
  A device is the machine: its firezone_id, or the certificate it attested
  with, identifies it on its own, without the actor who signed in or the
  site it served in the key. The actor- and site-scoped unique indexes give
  way to account-wide ones, and the type-specific column rules go, since a
  row may carry any combination of them.

  Rows that shared a key have to be merged first (the manual migration
  MergeDuplicateDevices), or the unique indexes cannot be built.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "firezone_id IS NOT NULL",
        name: :devices_account_id_firezone_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(
        :devices,
        [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial],
        where: "last_attested_cert_issuer IS NOT NULL AND last_attested_cert_serial IS NOT NULL",
        name: :devices_account_id_cert_issuer_serial_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :last_attested_mdm_device_id],
        where: "last_attested_mdm_device_id IS NOT NULL",
        name: :devices_account_id_last_attested_mdm_device_id_index,
        concurrently: true
      )
    )

    for name <- ~w[
          devices_account_id_actor_id_firezone_id_index
          devices_account_id_site_id_firezone_id_index
          devices_account_id_cert_issuer_serial_actor_id_index
          devices_account_id_actor_id_last_attested_mdm_device_id_index
        ] do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end

    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS device_type_client_fields")
    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS device_type_gateway_fields")
  end

  def down do
    create(
      constraint(:devices, :device_type_client_fields,
        check: "type != 'client' OR (actor_id IS NOT NULL AND site_id IS NULL)"
      )
    )

    create(
      constraint(:devices, :device_type_gateway_fields,
        check: "type != 'gateway' OR actor_id IS NULL"
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :firezone_id],
        where: "actor_id IS NOT NULL",
        name: :devices_account_id_actor_id_firezone_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :site_id, :firezone_id],
        where: "site_id IS NOT NULL",
        name: :devices_account_id_site_id_firezone_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(
        :devices,
        [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial, :actor_id],
        where: "last_attested_cert_issuer IS NOT NULL AND last_attested_cert_serial IS NOT NULL",
        name: :devices_account_id_cert_issuer_serial_actor_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :last_attested_mdm_device_id],
        where: "last_attested_mdm_device_id IS NOT NULL",
        name: :devices_account_id_actor_id_last_attested_mdm_device_id_index,
        concurrently: true
      )
    )

    for name <- ~w[
          devices_account_id_firezone_id_index
          devices_account_id_cert_issuer_serial_index
          devices_account_id_last_attested_mdm_device_id_index
        ] do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end
  end
end
