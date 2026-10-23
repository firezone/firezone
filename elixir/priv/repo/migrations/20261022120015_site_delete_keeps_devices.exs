defmodule Portal.Repo.Migrations.SiteDeleteKeepsDevices do
  @moduledoc """
  A device is a machine that outlives the sites it serves: deleting a site
  now clears the device's site column instead of deleting the device, and a
  gateway no longer has to name a site at all. Its assignments live in
  site_devices, which the site's deletion removes through its own key.

  The key is composite, so only the site column is cleared (a Postgres 15+
  form); the account column must stay.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE devices DROP CONSTRAINT devices_site_id_fkey")

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT devices_site_id_fkey
    FOREIGN KEY (account_id, site_id)
    REFERENCES sites(account_id, id)
    ON DELETE SET NULL (site_id)
    """)

    execute("ALTER TABLE devices DROP CONSTRAINT device_type_gateway_fields")

    create(
      constraint(:devices, :device_type_gateway_fields,
        check: "type != 'gateway' OR actor_id IS NULL"
      )
    )
  end

  def down do
    execute("ALTER TABLE devices DROP CONSTRAINT device_type_gateway_fields")

    create(
      constraint(:devices, :device_type_gateway_fields,
        check: "type != 'gateway' OR (site_id IS NOT NULL AND actor_id IS NULL)"
      )
    )

    execute("ALTER TABLE devices DROP CONSTRAINT devices_site_id_fkey")

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT devices_site_id_fkey
    FOREIGN KEY (account_id, site_id)
    REFERENCES sites(account_id, id)
    ON DELETE CASCADE
    """)
  end
end
