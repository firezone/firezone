defmodule Portal.PresenceTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.SiteDeviceFixtures

  alias Portal.Presence

  describe "Devices.online_gateway_ids_by_site/1" do
    test "groups connected gateway ids by site" do
      account = account_fixture()
      site_a = site_fixture(account: account)
      site_b = site_fixture(account: account)

      gateway_a1 = gateway_fixture(account: account, site: site_a)
      gateway_a2 = gateway_fixture(account: account, site: site_a, token: :single_owner)
      gateway_b = gateway_fixture(account: account, site: site_b)
      _offline = gateway_fixture(account: account, site: site_b)

      :ok = Presence.Devices.Account.track(gateway_a1)
      :ok = Presence.Devices.Account.track(gateway_a2)
      :ok = Presence.Devices.Account.track(gateway_b)

      assert Presence.Devices.online_gateway_ids_by_site(account.id) == %{
               site_a.id => MapSet.new([gateway_a1.id, gateway_a2.id]),
               site_b.id => MapSet.new([gateway_b.id])
             }
    end

    test "ignores connected clients" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      :ok = Presence.Devices.Account.track(client)

      assert Presence.Devices.online_gateway_ids_by_site(account.id) == %{}
    end

    test "lists a gateway under every site it is assigned to" do
      account = account_fixture()
      site_a = site_fixture(account: account)
      site_b = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site_a)
      site_device_fixture(device: gateway, site: site_b)

      :ok = gateway |> Repo.preload(:site_devices) |> Presence.Devices.Account.track()

      assert Presence.Devices.online_gateway_ids_by_site(account.id) == %{
               site_a.id => MapSet.new([gateway.id]),
               site_b.id => MapSet.new([gateway.id])
             }

      assert Presence.Devices.online_gateway_counts(account.id) == %{site_a.id => 1, site_b.id => 1}
    end

    test "a fetched gateway carries every site it is assigned to" do
      account = account_fixture()
      site_a = site_fixture(account: account)
      site_b = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site_a)
      site_device_fixture(device: gateway, site: site_b)

      :ok = gateway |> Repo.preload(:site_devices) |> Presence.Devices.Account.track()

      assert {:ok, online} = Presence.Devices.fetch_gateway(account.id, gateway.id)
      assert Enum.sort(Portal.Device.served_site_ids(online)) == Enum.sort([site_a.id, site_b.id])
      assert Portal.Device.serves_site?(online, site_b.id)
      refute Portal.Device.serves_site?(online, Ecto.UUID.generate())
    end

    test "falls back to the site column for a meta tracked without assignments" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      :ok = Presence.Devices.Account.track(gateway, %{site_ids: nil})

      assert Presence.Devices.online_gateway_ids_by_site(account.id) == %{
               site.id => MapSet.new([gateway.id])
             }
    end
  end
end
