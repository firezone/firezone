defmodule Portal.Repo.Migrations.PointDevicesGatewayTokenAtDeviceTokens do
  use Ecto.Migration

  # Gateway tokens are now written only to device_tokens. The new key is
  # added NOT VALID so devices is locked only briefly; the next migration
  # validates it without blocking writes.
  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    execute("ALTER TABLE device_tokens DROP CONSTRAINT device_tokens_gateway_token_fkey")

    execute("""
    ALTER TABLE devices
      DROP CONSTRAINT devices_gateway_token_id_fkey,
      ADD CONSTRAINT devices_gateway_token_id_fkey
        FOREIGN KEY (account_id, gateway_token_id)
        REFERENCES device_tokens (account_id, id)
        ON DELETE SET NULL (gateway_token_id)
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '5s'")

    execute("""
    ALTER TABLE devices
      DROP CONSTRAINT devices_gateway_token_id_fkey,
      ADD CONSTRAINT devices_gateway_token_id_fkey
        FOREIGN KEY (account_id, gateway_token_id)
        REFERENCES gateway_tokens (account_id, id)
        ON DELETE SET NULL (gateway_token_id)
        NOT VALID
    """)

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
