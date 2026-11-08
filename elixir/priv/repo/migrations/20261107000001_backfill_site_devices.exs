defmodule Portal.Repo.Migrations.BackfillSiteDevices do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO site_devices (account_id, site_id, device_id, inserted_at)
    SELECT account_id, site_id, id, inserted_at
    FROM devices
    WHERE site_id IS NOT NULL
    ON CONFLICT DO NOTHING
    """)
  end

  # Rows written by the app since the backfill are indistinguishable from it.
  def down, do: :ok
end
