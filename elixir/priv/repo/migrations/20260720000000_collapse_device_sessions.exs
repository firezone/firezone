defmodule Portal.Repo.Migrations.CollapseDeviceSessions do
  @moduledoc """
  Adds latest-session columns to devices, backfilled from the newest
  client_sessions / gateway_sessions row per device. Devices without any
  session keep NULLs.

  The columns are nullable catalog-only additions, so old code keeps running
  while they land. The backfill runs in batches through a temporary procedure
  that commits per batch, keyed on `last_seen_at IS NULL`: devices already
  written by the new connect path are skipped, so newer live data is never
  overwritten by history. Every statement is idempotent; re-run after a crash
  and it resumes where it left off.

  The token columns carry no foreign keys on purpose: they are telemetry
  written by the batched connect flush, and a token hard-deleted between
  connect and flush must not fail the whole batch. They are indexed by the
  follow-up AddDevicesTokenIndexes migration, after this backfill, so its
  updates stay out of the indexes.

  The session tables themselves are dropped by a follow-up manual migration
  once this release is fully rolled out.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @columns [
    {:public_key, :string},
    {:last_seen_user_agent, :string},
    {:last_seen_remote_ip, :inet},
    {:last_seen_remote_ip_location_region, :string},
    {:last_seen_remote_ip_location_city, :string},
    {:last_seen_remote_ip_location_lat, :float},
    {:last_seen_remote_ip_location_lon, :float},
    {:last_seen_version, :string},
    {:last_seen_at, :timestamptz},
    {:client_token_id, :uuid},
    {:gateway_token_id, :uuid}
  ]

  def up do
    alter table(:devices) do
      for {column, type} <- @columns do
        add_if_not_exists(column, type)
      end
    end

    execute("""
    CREATE OR REPLACE PROCEDURE backfill_device_sessions(
      dev_type text, sessions_tbl regclass, token_col text
    )
    LANGUAGE plpgsql
    AS $$
    DECLARE
      batch_count bigint;
      total bigint := 0;
    BEGIN
      LOOP
        EXECUTE format(
          'WITH batch AS (
             SELECT d.account_id, d.id
             FROM devices d
             WHERE d.type = %1$L
               AND d.last_seen_at IS NULL
               AND EXISTS (
                 SELECT 1 FROM %2$s s
                 WHERE s.account_id = d.account_id AND s.device_id = d.id
               )
             LIMIT 5000
           )
           UPDATE devices d
           SET public_key = s.public_key,
               last_seen_user_agent = s.user_agent,
               last_seen_remote_ip = s.remote_ip,
               last_seen_remote_ip_location_region = s.remote_ip_location_region,
               last_seen_remote_ip_location_city = s.remote_ip_location_city,
               last_seen_remote_ip_location_lat = s.remote_ip_location_lat,
               last_seen_remote_ip_location_lon = s.remote_ip_location_lon,
               last_seen_version = s.version,
               last_seen_at = s.inserted_at,
               %3$I = s.token_id
           FROM batch b
           CROSS JOIN LATERAL (
             SELECT s.public_key, s.user_agent, s.remote_ip,
                    s.remote_ip_location_region, s.remote_ip_location_city,
                    s.remote_ip_location_lat, s.remote_ip_location_lon,
                    s.version, s.inserted_at, s.%3$I AS token_id
             FROM %2$s s
             WHERE s.account_id = b.account_id AND s.device_id = b.id
             ORDER BY s.inserted_at DESC, s.id DESC
             LIMIT 1
           ) s
           WHERE d.account_id = b.account_id AND d.id = b.id',
          dev_type, sessions_tbl, token_col
        );
        GET DIAGNOSTICS batch_count = ROW_COUNT;

        COMMIT;
        total := total + batch_count;
        RAISE NOTICE 'Backfilled % % devices so far', total, dev_type;

        EXIT WHEN batch_count = 0;
      END LOOP;
    END;
    $$
    """)

    execute("CALL backfill_device_sessions('client', 'client_sessions', 'client_token_id')")
    execute("CALL backfill_device_sessions('gateway', 'gateway_sessions', 'gateway_token_id')")

    execute("DROP PROCEDURE backfill_device_sessions(text, regclass, text)")
  end

  def down do
    alter table(:devices) do
      for {column, type} <- @columns do
        remove_if_exists(column, type)
      end
    end
  end
end
