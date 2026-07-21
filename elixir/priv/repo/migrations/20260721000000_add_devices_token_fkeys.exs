defmodule Portal.Repo.Migrations.AddDevicesTokenFkeys do
  @moduledoc """
  Adds FKs from the devices token columns to their token tables, nilifying the
  token column when its token is hard-deleted so the columns never dangle.

  Raw SQL on purpose: `modify` with `references` re-issues `ALTER COLUMN ...
  TYPE`, which takes ACCESS EXCLUSIVE on devices even when the type is
  unchanged, while a bare ADD CONSTRAINT only takes SHARE ROW EXCLUSIVE.

  The constraints are added NOT VALID so writes are never blocked for the
  validation scan; dangling ids left by token deletions between the backfill
  and this migration are nulled out before validating.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    ALTER TABLE devices
      ADD CONSTRAINT devices_client_token_id_fkey
      FOREIGN KEY (account_id, client_token_id)
      REFERENCES client_tokens (account_id, id)
      ON DELETE SET NULL (client_token_id)
      NOT VALID
    """)

    execute("""
    ALTER TABLE devices
      ADD CONSTRAINT devices_gateway_token_id_fkey
      FOREIGN KEY (account_id, gateway_token_id)
      REFERENCES gateway_tokens (account_id, id)
      ON DELETE SET NULL (gateway_token_id)
      NOT VALID
    """)

    execute("""
    UPDATE devices SET client_token_id = NULL
    WHERE client_token_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM client_tokens t
        WHERE t.account_id = devices.account_id AND t.id = devices.client_token_id
      )
    """)

    execute("""
    UPDATE devices SET gateway_token_id = NULL
    WHERE gateway_token_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM gateway_tokens t
        WHERE t.account_id = devices.account_id AND t.id = devices.gateway_token_id
      )
    """)

    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_client_token_id_fkey")
    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_gateway_token_id_fkey")
  end

  def down do
    drop(constraint(:devices, "devices_client_token_id_fkey"))
    drop(constraint(:devices, "devices_gateway_token_id_fkey"))
  end
end
