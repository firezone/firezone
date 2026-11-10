defmodule Portal.Repo.Migrations.DropGatewayTokens do
  use Ecto.Migration

  # Dropping the table's own keys briefly locks accounts, sites and devices,
  # so a short lock_timeout keeps a blocked migration from stalling them.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")
    drop_if_exists(table(:gateway_tokens))
  end

  def down do
    raise Ecto.MigrationError, "gateway_tokens cannot be restored; its rows live in device_tokens"
  end
end
