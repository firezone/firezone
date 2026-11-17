defmodule Portal.PresenceTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures

  alias Portal.Presence

  describe "Devices.connected_gateways_in_site/2" do
    test "lists only the gateways connected to that site" do
      account = account_fixture()
      site = site_fixture(account: account)
      other_site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      other_gateway = gateway_fixture(account: account, site: other_site)
      client = client_fixture(account: account, actor: actor_fixture(account: account))

      :ok = Presence.Devices.connect(gateway, Ecto.UUID.generate())
      :ok = Presence.Devices.connect(other_gateway, Ecto.UUID.generate())
      :ok = Presence.Devices.connect(client, Ecto.UUID.generate())

      assert [%Portal.Device{id: id, online?: true}] =
               Presence.Devices.connected_gateways_in_site(account.id, site.id)

      assert id == gateway.id
      assert Presence.Devices.connected_gateways_in_site(account.id, Ecto.UUID.generate()) == []
    end

    test "places a gateway loaded without its site by the site it connects with" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      unloaded = Repo.get_by!(Portal.Device, account_id: account.id, id: gateway.id)

      :ok = Presence.Devices.connect(unloaded, Ecto.UUID.generate(), %{site_id: site.id})

      assert [_gateway] = Presence.Devices.connected_gateways_in_site(account.id, site.id)
    end

    test "places a gateway by its loaded site assignment" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      with_site_device =
        Portal.Device
        |> Repo.get_by!(account_id: account.id, id: gateway.id)
        |> Repo.preload(:site_device)

      :ok = Presence.Devices.connect(with_site_device, Ecto.UUID.generate())

      assert [_gateway] = Presence.Devices.connected_gateways_in_site(account.id, site.id)
    end
  end

  describe "Devices.fetch_gateway/3" do
    test "finds a gateway only in its own site" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor_fixture(account: account))

      :ok = Presence.Devices.connect(gateway, Ecto.UUID.generate())
      :ok = Presence.Devices.connect(client, Ecto.UUID.generate())

      assert {:ok, %Portal.Device{online?: true}} =
               Presence.Devices.fetch_gateway(account.id, gateway.id, site.id)

      assert Presence.Devices.fetch_gateway(account.id, gateway.id, Ecto.UUID.generate()) ==
               {:error, :offline}

      assert Presence.Devices.fetch_gateway(account.id, gateway.id, nil) == {:error, :offline}
      assert Presence.Devices.fetch_gateway(account.id, client.id, nil) == {:error, :offline}

      assert Presence.Devices.fetch_gateway(account.id, Ecto.UUID.generate(), site.id) ==
               {:error, :offline}
    end
  end

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
  end
end
