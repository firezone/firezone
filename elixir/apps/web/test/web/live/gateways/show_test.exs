defmodule Web.Auth.Gateways.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    gateway = Fixtures.Gateways.create_gateway(account: account, actor: actor, identity: identity)
    gateway = Repo.preload(gateway, :group)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      gateway: gateway
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    gateway: gateway,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/gateways/#{gateway}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when gateway is deleted", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    gateway = Fixtures.Gateways.delete_gateway(gateway)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Gateway Instance Groups"
    assert breadcrumbs =~ gateway.group.name_prefix
    assert breadcrumbs =~ gateway.name_suffix
  end

  test "renders gateway details", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    table =
      lv
      |> element("#gateway")
      |> render()
      |> vertical_table_to_map()

    assert table["instance group name"] =~ gateway.group.name_prefix
    assert table["instance name"] =~ gateway.name_suffix
    assert table["last seen"]
    assert table["location"] =~ to_string(gateway.last_seen_remote_ip)
    assert table["remote ipv4"] =~ to_string(gateway.ipv4)
    assert table["remote ipv6"] =~ to_string(gateway.ipv6)
    assert table["status"] =~ "Offline"
    assert table["user agent"] =~ gateway.last_seen_user_agent
    assert table["version"] =~ gateway.last_seen_version
  end

  test "renders gateway status", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    :ok = Domain.Gateways.connect_gateway(gateway)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    table =
      lv
      |> element("#gateway")
      |> render()
      |> vertical_table_to_map()

    assert table["status"] =~ "Online"
  end

  test "allows deleting gateways", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    assert lv
           |> element("button", "Delete Gateway")
           |> render_click() ==
             {:error, {:redirect, %{to: ~p"/#{account}/gateway_groups/#{gateway.group}"}}}

    assert Repo.get(Domain.Gateways.Gateway, gateway.id).deleted_at
  end
end
