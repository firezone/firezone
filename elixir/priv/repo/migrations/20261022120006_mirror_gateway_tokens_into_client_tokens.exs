defmodule Portal.Repo.Migrations.MirrorGatewayTokensIntoClientTokens do
  @moduledoc """
  Keeps client_tokens in step with every write to gateway_tokens while both
  tables exist. Done in the database so that pods still writing gateway_tokens
  during a rollout, and every code path that creates, rotates or revokes a
  gateway token, are covered without a second code change: a token is never
  valid in one table and gone from the other.

  The one-off copy runs again first, for tokens written between the previous
  copy and this trigger.
  """
  use Ecto.Migration

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
    CREATE OR REPLACE FUNCTION mirror_gateway_token()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        DELETE FROM client_tokens
        WHERE account_id = OLD.account_id AND id = OLD.id;
        RETURN NULL;
      END IF;

      INSERT INTO client_tokens (
        account_id, id, actor_id, secret_salt, secret_hash,
        device_id, site_id, rotated_at, expires_at, auth_provider_id,
        inserted_at, updated_at
      )
      SELECT
        NEW.account_id, NEW.id, a.id, NEW.secret_salt, NEW.secret_hash,
        NEW.device_id, NEW.site_id, NEW.rotated_at, NULL, NULL,
        NEW.inserted_at, now()
      FROM actors a
      WHERE a.account_id = NEW.account_id
        AND a.managed_by = 'system'
        AND a.type = 'service_account'
      LIMIT 1
      ON CONFLICT (account_id, id) DO UPDATE SET
        secret_salt = EXCLUDED.secret_salt,
        secret_hash = EXCLUDED.secret_hash,
        device_id = EXCLUDED.device_id,
        site_id = EXCLUDED.site_id,
        rotated_at = EXCLUDED.rotated_at,
        updated_at = now();

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER mirror_gateway_token
    AFTER INSERT OR UPDATE OR DELETE ON gateway_tokens
    FOR EACH ROW
    EXECUTE FUNCTION mirror_gateway_token()
    """)
  end

  def down do
    execute("DROP TRIGGER mirror_gateway_token ON gateway_tokens")
    execute("DROP FUNCTION mirror_gateway_token()")
  end
end
