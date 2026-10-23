defmodule Portal.Repo.Migrations.BackfillSiteDevices do
  @moduledoc """
  Every gateway so far serves exactly one site, recorded in `devices.site_id`.
  That link is copied into `site_devices` so the join table covers existing
  gateways before anything starts reading it.
  """
  use Ecto.Migration

  def up do
    execute(backfill_statement())
  end

  def down do
    execute("DELETE FROM site_devices")
  end

  def backfill_statement do
    """
    INSERT INTO site_devices (account_id, site_id, device_id, inserted_at)
    SELECT d.account_id, d.site_id, d.id, d.inserted_at
    FROM devices d
    WHERE d.site_id IS NOT NULL
    ON CONFLICT (account_id, site_id, device_id) DO NOTHING
    """
  end
end
