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

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
  end

  test "renders add group button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert button = Floki.find(html, "a[href='/#{account.slug}/sites/new']")
    assert Floki.text(button) =~ "Add Site"
  end

  test "renders sites table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Gateways.create_group(account: account)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    [row] =
      lv
      |> element("#groups")
      |> render()
      |> table_to_map()

    assert row == %{
             "site" => group.name,
             "online gateways" => "None",
             "resources" => resource.name
           }
  end

  test "updates sites table using presence", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Gateways.create_group(account: account)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Gateways.subscribe_to_gateways_presence_in_account(account)
    :ok = Domain.Gateways.connect_gateway(gateway)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _}
    assert_receive {:live_table_reloaded, "groups"}, 250

    wait_for(fn ->
      [row] =
        lv
        |> element("#groups")
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
    {:ok, group} = Domain.Gateways.create_internet_group(account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert has_element?(lv, "#internet-site-banner")
    assert lv |> element("#internet-site-banner") |> render() =~ "UPGRADE TO UNLOCK"
    assert has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/settings/billing']")

    refute has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/sites/#{group.id}']")
  end

  test "renders internet site with a status and manage button on paid plans", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account = Fixtures.Accounts.update_account(account, features: %{internet_resource: true})

    {:ok, group} = Domain.Gateways.create_internet_group(account)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Gateways.subscribe_to_gateways_presence_in_account(account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites")

    assert has_element?(lv, "#internet-site-banner")
    assert lv |> element("#internet-site-banner") |> render() =~ "Offline"
    refute has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/settings/billing']")

    assert has_element?(lv, "#internet-site-banner a[href='/#{account.slug}/sites/#{group.id}']")

    :ok = Domain.Gateways.connect_gateway(gateway)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _}
    assert_receive {:live_table_reloaded, "groups"}, 250
    assert lv |> element("#internet-site-banner") |> render() =~ "Online"
  end
end
