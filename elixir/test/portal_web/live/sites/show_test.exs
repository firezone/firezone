defmodule PortalWeb.Live.Sites.ShowTest do
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

  test "renders online gateways table with version", %{
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

    gateway_token = gateway_token_fixture(site: site, account: account)
    :ok = Portal.Presence.Gateways.connect(gateway, gateway_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}")

    rows =
      lv
      |> element("#gateways")
      |> render()
      |> table_to_map()

    rows
    |> with_table_row("instance", gateway.name, fn row ->
      assert row["version"] =~ "1.3.2"
      assert row["remote ip"] =~ "100.64.0.1"
      assert row["status"] =~ "Online"
    end)
  end

  test "renders gateway version after presence update", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    Portal.Config.put_env_override(:portal, :test_pid, self())

    gateway =
      gateway_fixture(
        account: account,
        site: site,
        last_seen_version: "1.3.2"
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}")

    gateway_token = gateway_token_fixture(site: site, account: account)
    :ok = Portal.Presence.Gateways.connect(gateway, gateway_token.id)
    assert_receive {:live_table_reloaded, "gateways"}

    lv
    |> element("#gateways")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", gateway.name, fn row ->
      assert row["version"] =~ "1.3.2"
      assert row["status"] =~ "Online"
    end)
  end
end
