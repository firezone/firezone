defmodule Portal.Repo.Migrations.ValidateClientTokenFkeys do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Validation scans each table without blocking its writes.
  def up do
    execute("ALTER TABLE policy_authorizations VALIDATE CONSTRAINT policy_authorizations_token_id_fkey")
    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_client_token_id_fkey")
  end

  def down, do: :ok
end
