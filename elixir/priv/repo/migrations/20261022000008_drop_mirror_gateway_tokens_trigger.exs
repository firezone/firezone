defmodule Portal.Repo.Migrations.DropMirrorGatewayTokensTrigger do
  @moduledoc """
  Nothing writes gateway_tokens any more: every reader and writer moved to
  client_tokens a release ago, so the mirror can go. The table itself is
  dropped in the next release, once no running code references it.
  """
  use Ecto.Migration

  def up do
    execute("DROP TRIGGER IF EXISTS mirror_gateway_token ON gateway_tokens")
    execute("DROP FUNCTION IF EXISTS mirror_gateway_token()")
  end

  def down do
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
end
