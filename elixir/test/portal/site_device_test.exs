defmodule Portal.SiteDeviceTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  alias Portal.SiteDevice

  setup do
    account = account_fixture()
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)

    %{account: account, site: site, gateway: gateway}
  end

  test "a device is assigned to a site once", %{account: account, site: site, gateway: gateway} do
    assert {:error, changeset} =
             %SiteDevice{}
             |> Ecto.Changeset.change(
               account_id: account.id,
               site_id: site.id,
               device_id: gateway.id
             )
             |> SiteDevice.changeset()
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).account_id
  end

  test "a device serves one site", %{account: account, gateway: gateway} do
    other_site = site_fixture(account: account)

    assert {:error, changeset} =
             %SiteDevice{}
             |> Ecto.Changeset.change(
               account_id: account.id,
               site_id: other_site.id,
               device_id: gateway.id
             )
             |> SiteDevice.changeset()
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).account_id
  end

  test "is removed with the site", %{site: site, gateway: gateway} do
    Repo.delete!(site)

    assert Repo.aggregate(site_devices(gateway), :count) == 0
  end

  test "is removed with the device", %{gateway: gateway} do
    Repo.delete!(gateway)

    assert Repo.aggregate(site_devices(gateway), :count) == 0
  end

  defp site_devices(device) do
    from(sd in SiteDevice,
      where: sd.account_id == ^device.account_id and sd.device_id == ^device.id
    )
  end
end
