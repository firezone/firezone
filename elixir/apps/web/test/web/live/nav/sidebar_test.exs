defmodule Web.Live.Nav.SidebarTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      identity: identity
    }
  end

  test "renders proper active sidebar item class for actors", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/actors")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/actors']")
    assert String.trim(Floki.text(item)) == "Actors"
  end

  test "renders proper active sidebar item class for groups", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/groups")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/groups']")
    assert String.trim(Floki.text(item)) == "Groups"
  end

  test "renders proper active sidebar item class for clients", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/clients")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/clients']")
    assert String.trim(Floki.text(item)) == "Clients"
  end

  test "renders proper active sidebar item class for gateways", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/gateway_groups")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/gateway_groups']")
    assert String.trim(Floki.text(item)) == "Gateways"
  end

  test "renders proper active sidebar item class for relays", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/relay_groups")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/relay_groups']")
    assert String.trim(Floki.text(item)) == "Relays"
  end

  test "renders proper active sidebar item class for resources", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/resources")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/resources']")
    assert String.trim(Floki.text(item)) == "Resources"
  end

  test "renders proper active sidebar item class for policies", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/policies")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/policies']")
    assert String.trim(Floki.text(item)) == "Policies"
  end

  test "renders proper active sidebar item class for account", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/settings/account")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/settings/account']")
    assert String.trim(Floki.text(item)) == "Account"
  end

  test "renders proper active sidebar item class for identity providers", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/settings/identity_providers")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/settings/identity_providers']")
    assert String.trim(Floki.text(item)) == "Identity Providers"
  end

  test "renders proper active sidebar item class for new OIDC identity provider", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/settings/identity_providers/openid_connect/new")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/settings/identity_providers']")
    assert String.trim(Floki.text(item)) == "Identity Providers"
  end

  test "renders proper active sidebar item class for dns", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} = live(authorize_conn(conn, identity), ~p"/#{account}/settings/dns")
    assert item = Floki.find(html, "a.bg-gray-100[href='/#{account.id}/settings/dns']")
    assert String.trim(Floki.text(item)) == "DNS"
  end
end
