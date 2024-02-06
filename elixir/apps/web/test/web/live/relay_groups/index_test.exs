defmodule Web.Live.RelayGroups.IndexTest do
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
    path = ~p"/#{account}/relay_groups"

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
      |> live(~p"/#{account}/relay_groups")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Relay Instance Groups"
  end

  test "renders add group button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups")

    assert button = Floki.find(html, "a[href='/#{account.slug}/relay_groups/new']")
    assert Floki.text(button) =~ "Add Instance Group"
  end

  test "renders groups table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Relays.create_group(account: account)
    relay = Fixtures.Relays.create_relay(account: account, group: group)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups")

    lv
    |> element("#groups")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", group.name, fn _row ->
      :ok
    end)
    |> with_table_row("instance", "#{relay.ipv4} #{relay.ipv6}", fn row ->
      assert row["status"] =~ "Offline"
      assert row["type"] =~ "self-hosted"
    end)
  end

  test "renders online status", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Relays.create_group(account: account)
    relay = Fixtures.Relays.create_relay(account: account, group: group)

    :ok = Domain.Relays.connect_relay(relay, "foo")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups")

    lv
    |> element("#groups")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", "#{relay.ipv4} #{relay.ipv6}", fn row ->
      assert row["status"] =~ "Online"
    end)
  end

  test "renders not found error when self_hosted_relays feature flag is false", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:self_hosted_relays, false)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups")
    end
  end
end
