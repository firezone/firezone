defmodule Web.Live.RelayGroups.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
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

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
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

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/relay_groups/new']")

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
    relay = Fixtures.Relays.create_relay(account: account, group: group) |> Repo.preload(:group)
    relay_token = Fixtures.Relays.create_token(group: relay.group, account: account)

    :ok = Domain.Relays.connect_relay(relay, "foo", relay_token.id)

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

  test "updates online status using relay presence", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Relays.create_group(account: account)
    relay = Fixtures.Relays.create_relay(account: account, group: group) |> Repo.preload(:group)
    relay_token = Fixtures.Relays.create_token(group: relay.group, account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups")

    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Relays.subscribe_to_relays_presence_in_group(group)

    :ok = Domain.Relays.connect_relay(relay, "foo", relay_token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_relays:" <> _}
    assert_receive {:live_table_reloaded, "groups"}, 250

    wait_for(fn ->
      lv
      |> element("#groups")
      |> render()
      |> table_to_map()
      |> with_table_row("instance", "#{relay.ipv4} #{relay.ipv6}", fn row ->
        assert row["status"] =~ "Online"
      end)
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
