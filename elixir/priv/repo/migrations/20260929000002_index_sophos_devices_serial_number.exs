defmodule Portal.Repo.Migrations.IndexSophosDevicesSerialNumber do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      index(:sophos_devices, [:account_id, :serial_number],
        where: "serial_number IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(index(:sophos_devices, [:account_id, :serial_number], concurrently: true))
  end
end
