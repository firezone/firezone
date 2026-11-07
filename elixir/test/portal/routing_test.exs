defmodule Portal.RoutingTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  alias Portal.Cache.Cacheable
  alias Portal.Relay
  alias Portal.Routing

  @berlin {52.52, 13.405}
  @paris {48.8566, 2.3522}
  @tokyo {35.6762, 139.6503}

  describe "select_receiver/3" do
    setup do
      account = account_fixture()
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site)
      cached = resource |> Repo.preload(:site) |> Cacheable.to_cache()

      %{account: account, site: site, resource: cached}
    end

    test "is offline with no device online in the site", %{account: account, resource: resource} do
      gateway_fixture(account: account)

      assert Routing.select_receiver(resource, initiator(account), []) == {:error, :offline}
    end

    test "tells a version mismatch apart from offline", %{account: account, site: site} = ctx do
      online_gateway(account, site, "1.0.0", @berlin)

      assert Routing.select_receiver(ctx.resource, initiator(account), []) ==
               {:error, :version_mismatch}
    end

    test "picks the nearest", %{account: account, site: site, resource: resource} do
      online_gateway(account, site, "1.5.0", @tokyo)
      paris = online_gateway(account, site, "1.5.0", @paris)

      assert {:ok, %{id: id}} = Routing.select_receiver(resource, initiator(account), [])
      assert id == paris.id
    end

    test "picks the newest among the nearest", %{account: account, site: site} = ctx do
      online_gateway(account, site, "1.5.9", @paris)
      newest = online_gateway(account, site, "1.5.10", @paris)

      assert {:ok, %{id: id}} = Routing.select_receiver(ctx.resource, initiator(account), [])
      assert id == newest.id
    end

    test "prefers a device the initiator is connected to", %{account: account, site: site} = ctx do
      online_gateway(account, site, "1.5.0", @paris)
      connected = online_gateway(account, site, "1.5.0", @tokyo)

      assert {:ok, %{id: id}} =
               Routing.select_receiver(ctx.resource, initiator(account), [connected.id])

      assert id == connected.id
    end
  end

  describe "select_relays/2" do
    test "picks the two nearest" do
      relays = [relay(@tokyo), relay(@paris), relay(@berlin)]

      assert Routing.select_relays(relays, @paris) |> Enum.map(&{&1.lat, &1.lon}) ==
               [@paris, @berlin]
    end

    test "defers relays without a location" do
      unknown = relay({nil, nil})
      tokyo = relay(@tokyo)

      assert Routing.select_relays([unknown, tokyo], @paris) == [tokyo, unknown]
    end

    test "picks two at random without a location of its own" do
      relays = [relay(@tokyo), relay(@paris), relay(@berlin)]

      assert length(Routing.select_relays(relays, {nil, nil})) == 2
    end
  end

  defp initiator(account) do
    %{account_id: account.id, version: "1.5.0", location: @berlin}
  end

  defp online_gateway(account, site, version, {lat, lon}) do
    gateway =
      gateway_fixture(
        account: account,
        site: site,
        last_seen_version: version,
        last_seen_remote_ip_location_lat: lat,
        last_seen_remote_ip_location_lon: lon
      )

    :ok = Portal.Presence.Devices.connect(gateway, Ecto.UUID.generate())
    gateway
  end

  defp relay({lat, lon}) do
    %Relay{id: Ecto.UUID.generate(), lat: lat, lon: lon}
  end
end
