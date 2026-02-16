defmodule PortalWeb.Live.Sites.Gateways.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GatewayFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    site = site_fixture(account: account)

    %{
      account: account,
      actor: actor,
      site: site
    }
  end

  test "renders gateways table with version", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    gateway =
      gateway_fixture(
        account: account,
        site: site,
        last_seen_version: "1.3.2"
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/gateways")

    [row] =
      lv
      |> element("#gateways")
      |> render()
      |> table_to_map()

    assert row["instance"] == gateway.name
    assert row["version"] =~ "1.3.2"
    assert row["remote ip"] =~ "100.64.0.1"
  end

  test "renders gateways table with version after presence update", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    gateway =
      gateway_fixture(
        account: account,
        site: site,
        last_seen_version: "1.3.2"
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/gateways")

    :ok = Portal.Presence.Gateways.Site.subscribe(site.id)
    gateway_token = gateway_token_fixture(site: site, account: account)
    :ok = Portal.Presence.Gateways.connect(gateway, gateway_token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:sites:" <> _}

    wait_for(fn ->
      [row] =
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()

      assert row["version"] =~ "1.3.2"
      assert row["status"] =~ "Online"
    end)
  end
end
