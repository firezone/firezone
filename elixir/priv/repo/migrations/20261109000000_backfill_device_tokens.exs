defmodule Portal.Repo.Migrations.BackfillDeviceTokens do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO actors (id, account_id, type, name, inserted_at, updated_at)
    SELECT gen_random_uuid(), account_id, 'legacy_gateway', 'Legacy Gateway', now(), now()
    FROM (SELECT DISTINCT account_id FROM gateway_tokens) AS accounts
    ON CONFLICT (account_id) WHERE type = 'legacy_gateway' DO NOTHING
    """)

    # Stamps first, so a stale active copy never blocks a new one.
    execute("""
    UPDATE device_tokens AS dt
    SET rotated_at = gt.rotated_at, updated_at = now()
    FROM gateway_tokens AS gt
    WHERE gt.account_id = dt.account_id
      AND gt.id = dt.id
      AND dt.rotated_at IS DISTINCT FROM gt.rotated_at
    """)

    execute("""
    INSERT INTO device_tokens (
      account_id, id, actor_id, device_id, site_id,
      secret_salt, secret_hash, rotated_at, inserted_at, updated_at
    )
    SELECT
      gt.account_id, gt.id, a.id, gt.device_id, gt.site_id,
      gt.secret_salt, gt.secret_hash, gt.rotated_at, gt.inserted_at, now()
    FROM gateway_tokens AS gt
    JOIN actors AS a ON a.account_id = gt.account_id AND a.type = 'legacy_gateway'
    ON CONFLICT DO NOTHING
    """)
  end

  # Rows written by the app since the backfill are indistinguishable from it.
  def down, do: :ok
end
