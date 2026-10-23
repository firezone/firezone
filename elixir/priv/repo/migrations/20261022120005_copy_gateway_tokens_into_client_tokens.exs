defmodule Portal.Repo.Migrations.CopyGatewayTokensIntoClientTokens do
  @moduledoc """
  Copies every gateway token into client_tokens under the same id, owned by
  the account's Infrastructure service account. Both tables hash secrets the
  same way, so a token already deployed on a gateway keeps verifying once the
  gateway socket reads from client_tokens. The gateway_tokens table stays
  until every reader has moved.

  With the gateway ids present, devices.token_id gets its foreign key.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @copy """
  INSERT INTO client_tokens (
    account_id, id, actor_id, secret_salt, secret_hash,
    device_id, site_id, rotated_at, expires_at, auth_provider_id,
    inserted_at, updated_at
  )
  SELECT
    gt.account_id, gt.id, a.id, gt.secret_salt, gt.secret_hash,
    gt.device_id, gt.site_id, gt.rotated_at, NULL, NULL,
    gt.inserted_at, gt.inserted_at
  FROM gateway_tokens gt
  JOIN actors a
    ON a.account_id = gt.account_id
   AND a.managed_by = 'system'
   AND a.type = 'service_account'
  ON CONFLICT (account_id, id) DO NOTHING
  """

  def up do
    execute(@copy)

    execute("""
    ALTER TABLE devices
      ADD CONSTRAINT devices_token_id_fkey
      FOREIGN KEY (account_id, token_id)
      REFERENCES client_tokens (account_id, id)
      ON DELETE SET NULL (token_id)
      NOT VALID
    """)

    execute("""
    UPDATE devices SET token_id = NULL
    WHERE token_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM client_tokens t
        WHERE t.account_id = devices.account_id AND t.id = devices.token_id
      )
    """)

    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_token_id_fkey")
  end

  def down do
    execute("ALTER TABLE devices DROP CONSTRAINT devices_token_id_fkey")

    execute("""
    DELETE FROM client_tokens ct
    USING gateway_tokens gt
    WHERE gt.account_id = ct.account_id AND gt.id = ct.id
    """)
  end
end
