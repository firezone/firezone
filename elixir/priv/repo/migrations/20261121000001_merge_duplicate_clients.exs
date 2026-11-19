defmodule Portal.Repo.Migrations.MergeDuplicateClients do
  use Ecto.Migration

  # Clients used to be keyed by actor and firezone_id, so one machine that
  # several people signed in on has a row for each of them. The most recently
  # seen row stays and takes over the others' users, device-bound tokens and
  # listed pool memberships. Their authorizations go with them; a connected
  # duplicate reconnects onto the kept row. The table stays locked against
  # writes until the unique index exists, so no new duplicate gets in between.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")
    execute("LOCK TABLE devices IN SHARE ROW EXCLUSIVE MODE")

    execute("""
    CREATE TEMP TABLE device_merges ON COMMIT DROP AS
    SELECT account_id, id AS duplicate_id, kept_id
    FROM (
      SELECT account_id, id,
             first_value(id) OVER (
               PARTITION BY account_id, firezone_id
               ORDER BY last_seen_at DESC NULLS LAST, id
             ) AS kept_id
      FROM devices
      WHERE type = 'client' AND firezone_id IS NOT NULL
    ) AS ranked
    WHERE id <> kept_id
    """)

    execute("""
    INSERT INTO device_actors (account_id, device_id, actor_id, first_seen_at, last_seen_at)
    SELECT m.account_id, m.kept_id, da.actor_id, min(da.first_seen_at), max(da.last_seen_at)
    FROM device_merges AS m
    JOIN device_actors AS da ON da.account_id = m.account_id AND da.device_id = m.duplicate_id
    GROUP BY m.account_id, m.kept_id, da.actor_id
    ON CONFLICT (account_id, device_id, actor_id) DO UPDATE
    SET first_seen_at = LEAST(device_actors.first_seen_at, EXCLUDED.first_seen_at),
        last_seen_at = GREATEST(device_actors.last_seen_at, EXCLUDED.last_seen_at)
    """)

    execute("""
    UPDATE device_tokens AS t
    SET device_id = m.kept_id
    FROM device_merges AS m
    WHERE t.account_id = m.account_id
      AND t.device_id = m.duplicate_id
      AND NOT EXISTS (
        SELECT 1 FROM device_tokens AS o
        WHERE o.account_id = m.account_id AND o.device_id = m.kept_id
      )
    """)

    execute("""
    UPDATE resources AS r
    SET device_membership_criteria = jsonb_set(
      r.device_membership_criteria,
      '{device,value}',
      (
        SELECT jsonb_agg(ids.id ORDER BY ids.id COLLATE "C")
        FROM (
          SELECT DISTINCT COALESCE(m.kept_id::text, listed.id) AS id
          FROM jsonb_array_elements_text(r.device_membership_criteria -> 'device' -> 'value') AS listed(id)
          LEFT JOIN device_merges AS m
            ON m.account_id = r.account_id AND m.duplicate_id::text = listed.id
        ) AS ids
      )
    )
    WHERE r.type = 'device_pool'
      AND r.device_membership_criteria -> 'device' ->> 'field' = 'id'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(r.device_membership_criteria -> 'device' -> 'value') AS listed(id)
        JOIN device_merges AS m
          ON m.account_id = r.account_id AND m.duplicate_id::text = listed.id
      )
    """)

    execute("""
    DELETE FROM devices AS d
    USING device_merges AS m
    WHERE d.account_id = m.account_id AND d.id = m.duplicate_id
    """)

    create(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "type = 'client'",
        name: :devices_account_id_client_firezone_id_index
      )
    )
  end

  def down do
    drop(index(:devices, [:account_id, :firezone_id], name: :devices_account_id_client_firezone_id_index))
  end
end
