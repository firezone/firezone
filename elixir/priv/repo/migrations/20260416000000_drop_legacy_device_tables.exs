defmodule Portal.Repo.Migrations.DropLegacyDeviceTables do
  use Ecto.Migration

  def up do
    execute("DROP FUNCTION IF EXISTS allocate_address(uuid, text, cidr, uuid, uuid)")

    drop_if_exists(table(:ipv4_addresses))
    drop_if_exists(table(:ipv6_addresses))
    drop_if_exists(table(:clients))
    drop_if_exists(table(:gateways))
  end

  def down do
    raise Ecto.MigrationError,
          "dropping legacy clients, gateways, and address tables is irreversible"
  end
end
