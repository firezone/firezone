defmodule Portal.Repo.Migrations.MirrorDeviceSiteIntoSiteDevices do
  @moduledoc """
  Keeps site_devices in step with every write to `devices.site_id` while
  both exist. Done in the database so that pods still writing the column
  during a rollout, and every code path that creates or moves a gateway, are
  covered without a second code change.

  The one-off copy runs again first, for gateways written between the
  previous copy and this trigger. Deleting a device removes its rows through
  the foreign key, so only inserts and site changes are mirrored.
  """
  use Ecto.Migration

  @copy """
  INSERT INTO site_devices (account_id, site_id, device_id, inserted_at)
  SELECT d.account_id, d.site_id, d.id, d.inserted_at
  FROM devices d
  WHERE d.site_id IS NOT NULL
  ON CONFLICT (account_id, site_id, device_id) DO NOTHING
  """

  def up do
    execute(@copy)

    execute("""
    CREATE OR REPLACE FUNCTION mirror_device_site()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.site_id IS NOT NULL
         AND OLD.site_id IS DISTINCT FROM NEW.site_id THEN
        DELETE FROM site_devices
        WHERE account_id = OLD.account_id
          AND site_id = OLD.site_id
          AND device_id = OLD.id;
      END IF;

      IF NEW.site_id IS NOT NULL THEN
        INSERT INTO site_devices (account_id, site_id, device_id, inserted_at)
        VALUES (NEW.account_id, NEW.site_id, NEW.id, now())
        ON CONFLICT (account_id, site_id, device_id) DO NOTHING;
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER mirror_device_site
    AFTER INSERT OR UPDATE OF site_id ON devices
    FOR EACH ROW
    EXECUTE FUNCTION mirror_device_site()
    """)
  end

  def down do
    execute("DROP TRIGGER mirror_device_site ON devices")
    execute("DROP FUNCTION mirror_device_site()")
  end
end
