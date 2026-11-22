defmodule Portal.Repo.Migrations.PointDevicesClientTokenAtDeviceTokens do
  use Ecto.Migration

  # As for policy_authorizations, in its own migration so each one locks one
  # busy table.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE devices
      DROP CONSTRAINT devices_client_token_id_fkey,
      ADD CONSTRAINT devices_client_token_id_fkey
        FOREIGN KEY (account_id, client_token_id)
        REFERENCES device_tokens (account_id, id)
        ON DELETE SET NULL (client_token_id)
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE devices
      DROP CONSTRAINT devices_client_token_id_fkey,
      ADD CONSTRAINT devices_client_token_id_fkey
        FOREIGN KEY (account_id, client_token_id)
        REFERENCES client_tokens (account_id, id)
        ON DELETE SET NULL (client_token_id)
        NOT VALID
    """)
  end
end
