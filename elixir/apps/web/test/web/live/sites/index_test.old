defmodule Web.Live.Sites.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/sites"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
  end

  test "renders add site button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert button =
             html |> Floki.parse_fragment!() |> Floki.find("a[href='/#{account.slug}/sites/new']")

    assert Floki.text(button) =~ "Add Site"
  end

  test "renders sites table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_site(account: account)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        site_id: site.id
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    [row] =
      lv
      |> element("#sites")
      |> render()
      |> table_to_map()

    assert row == %{
             "site" => site.name,
             "online gateways" => "None",
             "resources" => resource.name
           }
  end

  test "updates sites table using presence", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_site(account: account)
    token = Fixtures.Sites.create_token(account: account, site: site)
    gateway = Fixtures.Gateways.create_gateway(account: account, site: site)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Presence.Gateways.Account.subscribe(account.id)
    :ok = Domain.Presence.Gateways.connect(gateway, token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _}
    assert_receive {:live_table_reloaded, "sites"}, 250

    wait_for(fn ->
      [row] =
        lv
        |> element("#sites")
        |> render()
        |> table_to_map()

      assert row["online gateways"] =~ gateway.name
    end)
  end

  test "renders internet site with an option to upgrade on free plans", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_internet_site(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert has_element?(lv, "#internet-site-banner")
    assert lv |> element("#internet-site-banner") |> render() =~ "UPGRADE TO UNLOCK"
    assert has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/settings/billing']")

    refute has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/sites/#{site.id}']")
  end

  test "renders internet site with a status and manage button on paid plans", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account = Fixtures.Accounts.update_account(account, features: %{internet_resource: true})

    site = Fixtures.Gateways.create_internet_site(account: account)
    token = Fixtures.Sites.create_token(account: account, site: site)
    gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Presence.Gateways.Account.subscribe(account.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert has_element?(lv, "#internet-site-banner")
    assert lv |> element("#internet-site-banner") |> render() =~ "Offline"
    refute has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/settings/billing']")

    assert has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/sites/#{site.id}']")

    :ok = Domain.Presence.Gateways.connect(gateway, token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _}
    assert_receive {:live_table_reloaded, "sites"}, 250
    assert lv |> element("#internet-site-banner") |> render() =~ "Online"
  end
end
