defmodule Portal.Repo.Migrations.ValidateDevicesTokenIdFkey do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Validation scans the table without blocking its writes.
  def up do
    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_token_id_fkey")
  end

  def down, do: :ok
end
