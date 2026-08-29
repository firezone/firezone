defmodule Portal.Repo.Migrations.IndexPostureProviderJoinKeys do
  @moduledoc """
  Indexes the columns a Client is matched against in each provider's inventory.

  The remote identifier of every table is already the second half of its
  primary key, so only the alternate keys need one: the hardware serial, and
  the Entra device id that Intune and Defender both carry. The Clients list
  looks all of them up for a page of Clients at a time, so without these the
  page costs a sequential scan per configured provider.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      index(:intune_devices, [:account_id, :serial_number],
        where: "serial_number IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:intune_devices, [:account_id, :entra_device_id],
        where: "entra_device_id IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:iru_devices, [:account_id, :serial_number],
        where: "serial_number IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:defender_devices, [:account_id, :entra_device_id],
        where: "entra_device_id IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:santa_devices, [:account_id, :serial_number],
        where: "serial_number IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:sentinelone_devices, [:account_id, :serial_number],
        where: "serial_number IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(index(:sentinelone_devices, [:account_id, :serial_number], concurrently: true))
    drop_if_exists(index(:santa_devices, [:account_id, :serial_number], concurrently: true))
    drop_if_exists(index(:defender_devices, [:account_id, :entra_device_id], concurrently: true))
    drop_if_exists(index(:iru_devices, [:account_id, :serial_number], concurrently: true))
    drop_if_exists(index(:intune_devices, [:account_id, :entra_device_id], concurrently: true))
    drop_if_exists(index(:intune_devices, [:account_id, :serial_number], concurrently: true))
  end
end
