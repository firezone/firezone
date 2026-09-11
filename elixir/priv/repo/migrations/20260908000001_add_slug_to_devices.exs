defmodule Portal.Repo.Migrations.AddSlugToDevices do
  @moduledoc """
  Adds `slug` to devices: the DNS label a device answers at under `firezone.network`,
  unique per account and required.

  The slug is composed by `device_slug/2` and made unique by `next_free_device_slug/3`,
  which the app also calls when it inserts a device, so the backfill and the runtime
  agree. The backfill runs through a temporary procedure that commits per batch, keyed
  on `slug IS NULL`, so it resumes where it left off after a crash. The unique index is
  created first so the collision probe is an index lookup.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    alter table(:devices) do
      add_if_not_exists(:slug, :string)
    end

    create_if_not_exists(
      unique_index(:devices, [:account_id, :slug],
        name: :devices_account_id_slug_index,
        concurrently: true
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION device_slug_label(p_text text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
      SELECT trim(both '-' from regexp_replace(
        lower(regexp_replace(p_text, '[''’]', '', 'g')), '[^a-z0-9]+', '-', 'g'
      ))
    $$
    """)

    # The label for a device name: its first dotted part, prefixed with the owner's
    # first name unless the name already carries it, so a stock `iPhone` reads
    # `jamils-iphone`. Owner names may be emails; `NULL` means no owner (gateways,
    # service accounts).
    execute("""
    CREATE OR REPLACE FUNCTION device_slug(p_name text, p_owner_name text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
    DECLARE
      v_base text;
      v_owner text;
    BEGIN
      v_base := device_slug_label(split_part(p_name, '.', 1));

      IF v_base = '' THEN
        v_base := 'device';
      END IF;

      v_owner := device_slug_label(split_part(split_part(coalesce(p_owner_name, ''), '@', 1), ' ', 1));

      IF v_owner <> '' AND v_base !~ ('(^|-)' || v_owner || 's?(-|$)') THEN
        IF right(v_owner, 1) <> 's' THEN
          v_owner := v_owner || 's';
        END IF;

        v_base := v_owner || '-' || v_base;
      END IF;

      RETURN rtrim(left(v_base, 63), '-');
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION next_free_device_slug(p_account_id uuid, p_name text, p_owner_name text)
    RETURNS text
    LANGUAGE plpgsql
    AS $$
    DECLARE
      v_base text;
      v_candidate text;
      n integer := 1;
    BEGIN
      v_base := device_slug(p_name, p_owner_name);
      v_candidate := v_base;

      WHILE EXISTS (
        SELECT 1 FROM devices WHERE account_id = p_account_id AND slug = v_candidate
      ) LOOP
        n := n + 1;
        v_candidate := rtrim(left(v_base, 63 - length(n::text) - 1), '-') || '-' || n;
      END LOOP;

      RETURN v_candidate;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE PROCEDURE backfill_device_slugs()
    LANGUAGE plpgsql
    AS $$
    DECLARE
      device record;
      batch_count integer;
      total bigint := 0;
    BEGIN
      LOOP
        batch_count := 0;

        FOR device IN
          SELECT d.account_id, d.id, d.name,
            CASE WHEN a.type IN ('account_user', 'account_admin_user') THEN a.name END AS owner_name
          FROM devices d
          LEFT JOIN actors a ON a.account_id = d.account_id AND a.id = d.actor_id
          WHERE d.slug IS NULL
          ORDER BY d.inserted_at, d.id
          LIMIT 5000
        LOOP
          UPDATE devices
          SET slug = next_free_device_slug(device.account_id, device.name, device.owner_name)
          WHERE account_id = device.account_id AND id = device.id;

          batch_count := batch_count + 1;
        END LOOP;

        COMMIT;
        total := total + batch_count;
        RAISE NOTICE 'Backfilled % device slugs so far', total;

        EXIT WHEN batch_count = 0;
      END LOOP;
    END;
    $$
    """)

    execute("CALL backfill_device_slugs()")
    execute("DROP PROCEDURE backfill_device_slugs()")

    # A validated check constraint lets SET NOT NULL skip its own table scan.
    execute("ALTER TABLE devices ADD CONSTRAINT devices_slug_not_null CHECK (slug IS NOT NULL) NOT VALID")
    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_slug_not_null")
    execute("ALTER TABLE devices ALTER COLUMN slug SET NOT NULL")
    execute("ALTER TABLE devices DROP CONSTRAINT devices_slug_not_null")
  end

  def down do
    execute("DROP FUNCTION IF EXISTS next_free_device_slug(uuid, text, text)")
    execute("DROP FUNCTION IF EXISTS device_slug(text, text)")
    execute("DROP FUNCTION IF EXISTS device_slug_label(text)")

    drop_if_exists(index(:devices, [:account_id, :slug], name: :devices_account_id_slug_index))

    alter table(:devices) do
      remove_if_exists(:slug, :string)
    end
  end
end
