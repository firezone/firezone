defmodule Portal.Repo.Migrations.AddSiteDevicesDeviceIndex do
  use Ecto.Migration

  def change do
    create_if_not_exists(unique_index(:site_devices, [:account_id, :device_id]))
  end
end
