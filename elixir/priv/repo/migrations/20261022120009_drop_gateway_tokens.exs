defmodule Portal.Repo.Migrations.DropGatewayTokens do
  @moduledoc """
  Gateway tokens have lived in client_tokens for a release and nothing reads
  the gateway_tokens table or the two role-specific token columns on devices
  any more. Irreversible: the rows were copied, not moved, so nothing is lost.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_client_token_id_fkey")
    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_gateway_token_id_fkey")
    execute("DROP INDEX CONCURRENTLY IF EXISTS devices_account_id_client_token_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS devices_account_id_gateway_token_id_index")

    alter table(:devices) do
      remove(:client_token_id)
      remove(:gateway_token_id)
    end

    drop(table(:gateway_tokens))
  end

  def down do
    raise Ecto.MigrationError, "gateway_tokens and the legacy device token columns cannot be restored"
  end
end
