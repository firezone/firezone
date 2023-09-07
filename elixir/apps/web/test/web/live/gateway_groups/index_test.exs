defmodule Web.Live.GatewayGroups.IndexTest do
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
    assert live(conn, ~p"/#{account}/gateway_groups") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
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
      |> live(~p"/#{account}/gateway_groups")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Gateway Instance Groups"
  end

  test "renders add group button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups")

    assert button = Floki.find(html, "a[href='/#{account.slug}/gateway_groups/new']")
    assert Floki.text(button) =~ "Add Instance Group"
  end

  test "renders groups table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Gateways.create_group(account: account)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

    resources =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: group.id}]
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups")

    [%{"instance" => group_header} | group_rows] =
      lv
      |> element("#groups")
      |> render()
      |> table_to_map()

    assert group_header =~ group.name_prefix

    for tag <- group.tags do
      assert group_header =~ tag
    end

    assert group_header =~ resources.name

    group_rows
    |> with_table_row("instance", gateway.name_suffix, fn row ->
      assert row["remote ip"] =~ to_string(gateway.last_seen_remote_ip)
      assert row["status"] =~ "Offline"
    end)
  end

  test "renders online status", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Gateways.create_group(account: account)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)

    :ok = Domain.Gateways.connect_gateway(gateway)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups")

    lv
    |> element("#groups")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", gateway.name_suffix, fn row ->
      assert row["status"] =~ "Online"
    end)
  end
end
