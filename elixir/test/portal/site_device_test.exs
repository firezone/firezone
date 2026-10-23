defmodule Portal.SiteDeviceTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.SiteDeviceFixtures
  alias Portal.SiteDevice

  describe "site_devices" do
    test "one row per site and device" do
      site_device = site_device_fixture()

      assert {:error, changeset} =
               %SiteDevice{}
               |> Ecto.Changeset.cast(Map.from_struct(site_device), [
                 :account_id,
                 :site_id,
                 :device_id
               ])
               |> SiteDevice.changeset()
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).account_id
    end

    test "a device can be assigned to several sites" do
      account = account_fixture()
      device = gateway_fixture(account: account)
      site_device_fixture(device: device, site: site_fixture(account: account))
      site_device_fixture(device: device, site: site_fixture(account: account))

      assert device |> Repo.preload(:sites) |> Map.fetch!(:sites) |> length() == 2
    end

    test "is removed with the site" do
      account = account_fixture()
      site = site_fixture(account: account)
      site_device = site_device_fixture(site: site)

      Repo.delete!(site)

      refute Repo.get_by(SiteDevice,
               account_id: account.id,
               site_id: site_device.site_id,
               device_id: site_device.device_id
             )
    end

    test "is removed with the device" do
      account = account_fixture()
      device = gateway_fixture(account: account)
      site_device = site_device_fixture(device: device)

      Repo.delete!(device)

      refute Repo.get_by(SiteDevice,
               account_id: account.id,
               site_id: site_device.site_id,
               device_id: site_device.device_id
             )
    end
  end
end
