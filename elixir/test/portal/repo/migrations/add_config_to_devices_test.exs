defmodule Portal.Repo.Migrations.AddConfigToDevicesTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  alias Portal.Accounts.Config
  alias Portal.Device

  # Runs only the backfill: the ALTER would lock devices against every other test.
  @migration Path.expand("../../../../priv/repo/migrations/20261122053224_add_config_to_devices.exs", __DIR__)
  @external_resource @migration
  [backfill] = Regex.run(~r/UPDATE devices.*?(?=""")/s, File.read!(@migration))
  @backfill backfill

  test "sets every gateway to the default config and leaves clients on the account's" do
    account = account_fixture()
    client = client_fixture(account: account)
    gateway = gateway_fixture(account: account)
    custom = gateway_fixture(account: account)

    put_config(custom, %Config{
      search_domain: "example.com",
      clients_upstream_dns: %Portal.UpstreamDNS{type: :secure, doh_provider: :quad9}
    })

    assert raw_config(gateway) == nil

    Repo.query!(@backfill)

    assert Repo.get_by!(Device, id: gateway.id).config == Config.default_config()
    assert Repo.get_by!(Device, id: client.id).config == nil

    assert %Config{search_domain: "example.com", clients_upstream_dns: %{type: :secure, doh_provider: :quad9}} =
             Repo.get_by!(Device, id: custom.id).config
  end

  test "writes the same JSON as the schema does for the default config" do
    account = account_fixture()
    backfilled = gateway_fixture(account: account)
    written = gateway_fixture(account: account)
    put_config(written, Config.default_config())

    Repo.query!(@backfill)

    assert raw_config(backfilled) == raw_config(written)
    assert raw_config(backfilled) == JSON.decode!(JSON.encode!(Ecto.embedded_dump(Config.default_config(), :json)))
  end

  defp put_config(device, config) do
    device
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:config, config)
    |> Repo.update!()
  end

  defp raw_config(device) do
    Repo.one!(from(d in "devices", where: d.id == type(^device.id, :binary_id), select: d.config))
  end
end
