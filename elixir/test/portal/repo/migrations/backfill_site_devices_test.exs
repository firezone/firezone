defmodule Portal.Repo.Migrations.BackfillSiteDevicesTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  alias Portal.SiteDevice

  Code.require_file("priv/repo/migrations/20261022120013_backfill_site_devices.exs")
  alias Portal.Repo.Migrations.BackfillSiteDevices

  setup do
    account = account_fixture()
    %{account: account}
  end

  defp backfill do
    # Rows the mirror trigger wrote on insert are cleared so the statement is
    # what puts them back.
    Repo.delete_all(SiteDevice)
    Repo.query!(BackfillSiteDevices.backfill_statement())
  end

  test "copies every gateway's site", %{account: account} do
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)

    backfill()

    row = Repo.get_by(SiteDevice, account_id: account.id, site_id: site.id, device_id: gateway.id)
    assert DateTime.compare(row.inserted_at, gateway.inserted_at) == :eq
  end

  test "skips devices without a site", %{account: account} do
    client_fixture(account: account)

    backfill()

    assert Repo.aggregate(SiteDevice, :count) == 0
  end

  test "runs again without duplicating rows", %{account: account} do
    gateway_fixture(account: account)

    backfill()
    Repo.query!(BackfillSiteDevices.backfill_statement())

    assert Repo.aggregate(SiteDevice, :count) == 1
  end
end
