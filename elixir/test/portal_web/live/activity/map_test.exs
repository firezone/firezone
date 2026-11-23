defmodule PortalWeb.Activity.MapTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  alias PortalWeb.Activity.Land

  setup do
    account = account_fixture()
    admin = admin_actor_fixture(account: account)
    person = actor_fixture(account: account, name: "Sam Okafor")
    site = site_fixture(account: account)
    resource = resource_fixture(account: account, site: site, name: "GitLab")

    %{account: account, admin: admin, person: person, site: site, resource: resource}
  end

  defp place(device, lat, lon, city) do
    device
    |> Ecto.Changeset.change(
      last_seen_remote_ip_location_lat: lat,
      last_seen_remote_ip_location_lon: lon,
      last_seen_remote_ip_location_city: city,
      last_seen_remote_ip_location_region: "DE"
    )
    |> Portal.Repo.update!()
  end

  test "renders the map and an empty list", %{conn: conn, account: account, admin: admin} do
    {:ok, lv, html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity/map")

    assert html =~ "Live map"
    assert has_element?(lv, "#activity-map[phx-hook='ActivityMap'] svg path")
    assert has_element?(lv, "#activity-map-empty")
  end

  test "polling adds new authorizations to the list and the map", %{
    conn: conn,
    account: account,
    admin: admin,
    person: person,
    site: site,
    resource: resource
  } do
    {:ok, lv, _html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity/map")

    client = person |> then(&client_fixture(account: account, actor: &1)) |> place(52.52, 13.4, "Berlin")
    gateway = gateway_fixture(account: account, site: site) |> place(50.11, 8.68, "Frankfurt")

    authorization =
      policy_authorization_fixture(
        account: account,
        actor: person,
        client: client,
        gateway: gateway,
        resource: resource,
        site: site
      )

    send(lv.pid, :poll)

    assert has_element?(lv, "#connection-#{authorization.id}", "GitLab")
    assert has_element?(lv, "#connection-#{authorization.id}", "Berlin, Germany")
    assert has_element?(lv, "#connection-#{authorization.id}", "Frankfurt, Germany")
    refute has_element?(lv, "#activity-map-empty")

    from = Land.project(52.52, 13.4)
    to = Land.project(50.11, 8.68)

    assert_push_event(lv, "activity-map:connections", %{
      animate: true,
      connections: [%{id: id, from: ^from, to: ^to}]
    })

    assert id == authorization.id

    send(lv.pid, :poll)
    refute_push_event(lv, "activity-map:connections", %{animate: true}, 100)
  end

  test "does not crash on devices without a place", %{
    conn: conn,
    account: account,
    admin: admin,
    person: person,
    site: site,
    resource: resource
  } do
    {:ok, lv, _html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity/map")

    authorization =
      policy_authorization_fixture(account: account, actor: person, site: site, resource: resource)

    send(lv.pid, :poll)

    assert has_element?(lv, "#connection-#{authorization.id}", "Unknown place")
    assert_push_event(lv, "activity-map:connections", %{connections: [%{from: nil, to: nil}]})
  end

  test "ignores other accounts", %{conn: conn, account: account, admin: admin} do
    {:ok, lv, _html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity/map")

    other = policy_authorization_fixture()
    send(lv.pid, :poll)

    refute has_element?(lv, "#connection-#{other.id}")
    assert has_element?(lv, "#activity-map-empty")
  end

  test "projects coordinates onto the grid" do
    assert Land.project(84.0, -180.0) == [0.0, 0.0]
    assert Land.project(0.0, 0.0) == [120.0, 56.0]
    assert Land.project(nil, 10.0) == nil
    assert Land.path() =~ ~r/^M\d/
  end
end
