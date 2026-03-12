defmodule PortalWeb.Live.Sites.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures
  import Portal.ResourceFixtures
  import Portal.GatewayFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    # Sites index requires an internet resource to be present (or the page crashes)
    internet_site = internet_site_fixture(account: account)
    internet_resource_fixture(account: account, site: internet_site)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/sites"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
  end

  test "renders add site button", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    assert button =
             html |> Floki.parse_fragment!() |> Floki.find("a[href='/#{account.slug}/sites/new']")

    assert Floki.text(button) =~ "Add Site"
  end

  test "renders sites table", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    site = site_fixture(account: account)
    _resource = resource_fixture(account: account, site: site)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    rows =
      lv
      |> element("#sites")
      |> render()
      |> table_to_map()

    site_row = Enum.find(rows, fn row -> row["site"] == site.name end)
    assert site_row
    assert site_row["online gateways"] =~ "None"
    assert site_row["resources"] =~ "1 resource"
  end

  test "updates sites table using presence", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    Portal.Config.put_env_override(:portal, :test_pid, self())
    site = site_fixture(account: account)
    gateway_token = gateway_token_fixture(account: account, site: site)
    gateway = gateway_fixture(account: account, site: site)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    :ok = Portal.Presence.Gateways.Site.subscribe(site.id)
    :ok = Portal.Presence.Gateways.Account.subscribe(account.id)
    :ok = Portal.Presence.Gateways.connect(gateway, gateway_token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:sites:" <> _}
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _}
    assert_receive {:live_table_reloaded, "sites"}, 500

    wait_for(fn ->
      rows =
        lv
        |> element("#sites")
        |> render()
        |> table_to_map()

      site_row = Enum.find(rows, fn row -> row["site"] == site.name end)
      assert site_row
      assert site_row["online gateways"] =~ "1"
    end)
  end

  test "renders internet site with an option to upgrade on free plans", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    assert has_element?(lv, "#internet-site-banner")
    assert lv |> element("#internet-site-banner") |> render() =~ "UPGRADE TO UNLOCK"
    assert has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/settings/billing']")
  end

  test "renders internet site with a status and manage button on paid plans", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    Portal.Config.put_env_override(:portal, :test_pid, self())
    account = update_account(account, features: %{internet_resource: true})

    internet_site = Repo.get_by!(Portal.Site, account_id: account.id, managed_by: :system)
    gateway_token = gateway_token_fixture(account: account, site: internet_site)
    gateway = gateway_fixture(account: account, site: internet_site)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    assert has_element?(lv, "#internet-site-banner")
    assert lv |> element("#internet-site-banner") |> render() =~ "Offline"
    refute has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/settings/billing']")

    assert has_element?(
             lv,
             "#internet-site-banner a[href='/#{account.slug}/sites/#{internet_site.id}']"
           )

    :ok = Portal.Presence.Gateways.Account.subscribe(account.id)
    :ok = Portal.Presence.Gateways.connect(gateway, gateway_token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _}
    assert_receive {:live_table_reloaded, "sites"}, 250
    assert lv |> element("#internet-site-banner") |> render() =~ "Online"
  end
end
