defmodule Portal.Repo.Migrations.PointDevicesGatewayTokenAtDeviceTokens do
  use Ecto.Migration

  # Gateway tokens are now written only to device_tokens. The new key is
  # added NOT VALID so devices is locked only briefly, and the short
  # lock_timeout stops a blocked migration from queueing every devices query
  # behind it. The next migration validates the key without blocking writes.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

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
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE devices
      DROP CONSTRAINT devices_gateway_token_id_fkey,
      ADD CONSTRAINT devices_gateway_token_id_fkey
        FOREIGN KEY (account_id, gateway_token_id)
        REFERENCES gateway_tokens (account_id, id)
        ON DELETE SET NULL (gateway_token_id)
        NOT VALID
    """)
  end
end
