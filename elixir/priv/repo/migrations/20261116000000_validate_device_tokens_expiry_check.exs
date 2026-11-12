defmodule Portal.Repo.Migrations.ValidateDeviceTokensExpiryCheck do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Validation scans the table without blocking its writes.
  def up do
    execute("ALTER TABLE device_tokens VALIDATE CONSTRAINT device_tokens_unbound_expires")
  end

  def down, do: :ok
end
