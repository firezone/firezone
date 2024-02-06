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
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

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

    :ok = Domain.Gateways.connect_gateway(gateway)

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
             "online gateways" => gateway.name,
             "resources" => resource.name
           }
  end
end
