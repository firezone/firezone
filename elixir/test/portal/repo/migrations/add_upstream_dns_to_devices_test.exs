defmodule Portal.Repo.Migrations.AddUpstreamDnsToDevicesTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  alias Portal.Device

  # Runs only the backfill: the ALTER would lock devices against every other test.
  @migration Path.expand("../../../../priv/repo/migrations/20261122053224_add_upstream_dns_to_devices.exs", __DIR__)
  @external_resource @migration
  [backfill] = Regex.run(~r/UPDATE devices.*?(?=""")/s, File.read!(@migration))
  @backfill backfill

  test "sets every gateway to its own resolvers and leaves clients on the account setting" do
    account = account_fixture()
    client = client_fixture(account: account)
    gateway = gateway_fixture(account: account)
    custom = gateway_fixture(account: account)

    custom
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:upstream_dns, %Portal.UpstreamDNS{type: :secure, doh_provider: :quad9})
    |> Repo.update!()

    assert raw_upstream_dns(gateway) == nil

    Repo.query!(@backfill)

    assert %Portal.UpstreamDNS{type: :system} = Repo.get_by!(Device, id: gateway.id).upstream_dns
    assert Repo.get_by!(Device, id: client.id).upstream_dns == nil
    assert %Portal.UpstreamDNS{type: :secure, doh_provider: :quad9} = Repo.get_by!(Device, id: custom.id).upstream_dns
  end

  test "writes the same JSON as the schema does" do
    account = account_fixture()
    backfilled = gateway_fixture(account: account)
    written = gateway_fixture(account: account)

    written
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:upstream_dns, %Portal.UpstreamDNS{type: :system})
    |> Repo.update!()

    Repo.query!(@backfill)

    assert raw_upstream_dns(backfilled) == raw_upstream_dns(written)
  end

  defp raw_upstream_dns(device) do
    Repo.one!(from(d in "devices", where: d.id == type(^device.id, :binary_id), select: d.upstream_dns))
  end
end
