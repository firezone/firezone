defmodule Web.Live.Relays.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    relay = Fixtures.Relays.create_relay(account: account, actor: actor, identity: identity)
    relay = Repo.preload(relay, :group)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      relay: relay
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    relay: relay,
    conn: conn
  } do
    path = ~p"/#{account}/relays/#{relay}"

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
    relay: relay,
    identity: identity,
    conn: conn
  } do
    relay = Fixtures.Relays.delete_relay(relay)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    relay: relay,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Relay Instance Groups"
    assert breadcrumbs =~ relay.group.name
    assert breadcrumbs =~ to_string(relay.ipv4)
  end

  test "renders relay details", %{
    account: account,
    relay: relay,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")

    table =
      lv
      |> element("#relay")
      |> render()
      |> vertical_table_to_map()

    assert table["instance group name"] =~ relay.group.name
    assert table["last started"]
    assert table["last seen remote ip"] =~ to_string(relay.last_seen_remote_ip)
    assert table["ipv4 set by public_ip4_addr"] =~ to_string(relay.ipv4)
    assert table["ipv6 set by public_ip6_addr"] =~ to_string(relay.ipv6)
    assert table["status"] =~ "Offline"
    assert table["user agent"] =~ relay.last_seen_user_agent
    assert table["version"] =~ relay.last_seen_version
  end

  test "renders relay status", %{
    account: account,
    relay: relay,
    identity: identity,
    subject: _subject,
    conn: conn
  } do
    relay_token = Fixtures.Relays.create_token(group: relay.group, account: account)
    :ok = Domain.Relays.connect_relay(relay, "foo", relay_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")

    table =
      lv
      |> element("#relay")
      |> render()
      |> vertical_table_to_map()

    assert table["status"] =~ "Online"
  end

  test "updates relay status using presence", %{
    account: account,
    relay: relay,
    identity: identity,
    subject: _subject,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")

    :ok = Domain.Relays.subscribe_to_relays_presence_in_group(relay.group_id)
    relay_token = Fixtures.Relays.create_token(group: relay.group, account: account)
    :ok = Domain.Relays.connect_relay(relay, "foo", relay_token.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_relays:" <> _}

    wait_for(fn ->
      table =
        lv
        |> element("#relay")
        |> render()
        |> vertical_table_to_map()

      assert table["status"] =~ "Online"
    end)
  end

  test "allows deleting relays", %{
    account: account,
    relay: relay,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")

    lv
    |> element("button[type=submit]", "Delete Relay")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/relay_groups/#{relay.group}")

    refute Repo.get(Domain.Relays.Relay, relay.id)
  end

  test "renders not found error when self_hosted_relays feature flag is false", %{
    account: account,
    identity: identity,
    relay: relay,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:self_hosted_relays, false)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relays/#{relay}")
    end
  end
end
