defmodule Portal.Repo.Migrations.MirrorDeviceSiteIntoSiteDevicesTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  alias Portal.SiteDevice

  setup do
    account = account_fixture()
    %{account: account}
  end

  defp site_ids(device) do
    from(sd in SiteDevice,
      where: sd.account_id == ^device.account_id and sd.device_id == ^device.id,
      select: sd.site_id
    )
    |> Repo.all()
  end

  test "a gateway created with a site is assigned to it", %{account: account} do
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)

    assert site_ids(gateway) == [site.id]
  end

  test "moving a gateway to another site moves the assignment", %{account: account} do
    gateway = gateway_fixture(account: account)
    other = site_fixture(account: account)

    gateway |> Ecto.Changeset.change(site_id: other.id) |> Repo.update!()

    assert site_ids(gateway) == [other.id]
  end

  test "an update that leaves the site alone keeps other assignments", %{account: account} do
    gateway = gateway_fixture(account: account)
    extra = site_fixture(account: account)

    Repo.insert!(%SiteDevice{account_id: account.id, site_id: extra.id, device_id: gateway.id})
    gateway |> Ecto.Changeset.change(name: "renamed") |> Repo.update!()

    assert Enum.sort(site_ids(gateway)) == Enum.sort([gateway.site_id, extra.id])
  end

  test "a client records nothing", %{account: account} do
    client = client_fixture(account: account)

    assert site_ids(client) == []
  end
end
