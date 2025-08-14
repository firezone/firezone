defmodule Web.Live.RelayGroups.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Relays.create_group(account: account, subject: subject)
    relay = Fixtures.Relays.create_relay(account: account, group: group)
    relay = Repo.preload(relay, :group)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      group: group,
      relay: relay
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    group: group,
    conn: conn
  } do
    path = ~p"/#{account}/relay_groups/#{group}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "raises NotFoundError for deleted relay", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Relays.delete_group(group)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")
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
      |> live(~p"/#{account}/relay_groups/#{group}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Relay Instance Groups"
    assert breadcrumbs =~ group.name
  end

  test "allows editing relay groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")

    assert lv
           |> element("a", "Edit Instance Group")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/relay_groups/#{group}/edit", kind: :push}}}
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
      |> live(~p"/#{account}/relay_groups/#{group}")

    table =
      lv
      |> element("#group")
      |> render()
      |> vertical_table_to_map()

    assert table["instance group name"] =~ group.name
    assert table["created"] =~ actor.name
  end

  test "renders relays table", %{
    account: account,
    identity: identity,
    group: group,
    relay: relay,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")

    lv
    |> element("#relays")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", "#{relay.ipv4} #{relay.ipv6}", fn row ->
      assert row["status"] =~ "Offline"
    end)
  end

  test "renders relay status", %{
    account: account,
    group: group,
    relay: relay,
    identity: identity,
    conn: conn
  } do
    relay = Repo.preload(relay, :group)
    relay_token = Fixtures.Relays.create_token(group: relay.group, account: account)

    :ok = Domain.Relays.connect_relay(relay, "foo", relay_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")

    lv
    |> element("#relays")
    |> render()
    |> table_to_map()
    |> with_table_row("instance", "#{relay.ipv4} #{relay.ipv6}", fn row ->
      assert row["status"] =~ "Online"
    end)
  end

  test "updates relay status using presence", %{
    account: account,
    group: group,
    relay: relay,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")

    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Relays.subscribe_to_relays_presence_in_group(group)
    relay = Repo.preload(relay, :group)
    relay_token = Fixtures.Relays.create_token(group: relay.group, account: account)

    :ok = Domain.Relays.connect_relay(relay, "foo", relay_token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_relays:" <> _}
    assert_receive {:live_table_reloaded, "relays"}, 250

    wait_for(fn ->
      lv
      |> element("#relays")
      |> render()
      |> table_to_map()
      |> with_table_row("instance", "#{relay.ipv4} #{relay.ipv6}", fn row ->
        assert row["status"] =~ "Online"
      end)
    end)
  end

  test "allows deleting relays", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")

    lv
    |> element("button[type=submit]", "Delete")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/relay_groups")

    refute Repo.get(Domain.Relays.Group, group.id)
  end

  test "allows revoking all tokens", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")

    assert lv
           |> element("button[type=submit]", "Revoke All")
           |> render_click() =~ "1 token(s) were revoked."

    refute Repo.get_by(Domain.Tokens.Token, relay_group_id: group.id)
  end

  test "renders not found error when self_hosted_relays feature flag is false", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:self_hosted_relays, false)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}")
    end
  end
end
