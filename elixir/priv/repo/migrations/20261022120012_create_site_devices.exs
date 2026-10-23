defmodule Portal.Repo.Migrations.CreateSiteDevices do
  @moduledoc """
  A device serves the resources of the sites it is assigned to. Today that
  is one site per gateway in `devices.site_id`; this table lets any device
  be assigned to any number of sites, and is kept in step with the column
  until every reader has moved over.

  Deleting the site or the device removes the rows.
  """
  use Ecto.Migration

  def change do
    create table(:site_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:site_id, :binary_id, null: false, primary_key: true)
      add(:device_id, :binary_id, null: false, primary_key: true)

      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    execute(
      """
      ALTER TABLE site_devices
      ADD CONSTRAINT site_devices_site_id_fkey
      FOREIGN KEY (account_id, site_id) REFERENCES sites(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE site_devices DROP CONSTRAINT site_devices_site_id_fkey"
    )

    execute(
      """
      ALTER TABLE site_devices
      ADD CONSTRAINT site_devices_device_id_fkey
      FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE site_devices DROP CONSTRAINT site_devices_device_id_fkey"
    )

    # The primary key covers a site's devices; this covers a device's sites.
    create(index(:site_devices, [:account_id, :device_id]))
  end
end
