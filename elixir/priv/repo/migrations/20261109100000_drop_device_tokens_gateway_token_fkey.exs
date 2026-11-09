defmodule Portal.Repo.Migrations.DropDeviceTokensGatewayTokenFkey do
  use Ecto.Migration

  # Revokes delete from both tables in the app, so the cascade is no longer
  # needed. A short lock_timeout keeps a blocked migration from stalling
  # token verification.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")
    execute("ALTER TABLE device_tokens DROP CONSTRAINT device_tokens_gateway_token_fkey")
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE device_tokens
      ADD CONSTRAINT device_tokens_gateway_token_fkey
        FOREIGN KEY (account_id, id)
        REFERENCES gateway_tokens (account_id, id)
        ON DELETE CASCADE
        NOT VALID
    """)
  end
end
