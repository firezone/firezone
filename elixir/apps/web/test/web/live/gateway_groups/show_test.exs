defmodule Web.Live.GatewayGroups.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Gateways.create_group(account: account, subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    gateway = Repo.preload(gateway, :group)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      group: group,
      gateway: gateway
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    group: group,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/gateway_groups/#{group}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when gateway is deleted", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Gateways.delete_group(group)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Gateway Instance Groups"
    assert breadcrumbs =~ group.name_prefix
  end

  test "allows editing gateway groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")

    assert lv
           |> element("a", "Edit Instance Group")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/gateway_groups/#{group}/edit", kind: :push}}}
  end

  test "renders group details", %{
    account: account,
    actor: actor,
    identity: identity,
    group: group,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")

    table =
      lv
      |> element("#group")
      |> render()
      |> vertical_table_to_map()

    assert table["instance group name"] =~ group.name_prefix
    assert table["created"] =~ actor.name
  end

  test "renders gateways table", %{
    account: account,
    actor: actor,
    identity: identity,
    group: group,
    gateway: gateway,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")

    lv
    |> element("#gateways")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", gateway.name_suffix, fn row ->
      assert row["token created at"] =~ actor.name
      assert row["status"] =~ "Offline"
    end)
  end

  test "renders gateway status", %{
    account: account,
    group: group,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    :ok = Domain.Gateways.connect_gateway(gateway)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")

    lv
    |> element("#gateways")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", gateway.name_suffix, fn row ->
      assert gateway.last_seen_remote_ip
      assert row["remote ip"] =~ to_string(gateway.last_seen_remote_ip)
      assert row["status"] =~ "Online"
      assert row["token created at"]
    end)
  end

  test "allows deleting gateways", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateway_groups/#{group}")

    assert lv
           |> element("button", "Delete Gateway")
           |> render_click() ==
             {:error, {:redirect, %{to: ~p"/#{account}/gateway_groups"}}}

    assert Repo.get(Domain.Gateways.Group, group.id).deleted_at
  end
end
