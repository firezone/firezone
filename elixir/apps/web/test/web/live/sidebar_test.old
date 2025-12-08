defmodule Web.SidebarTest do
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

  test "hides dropdown when path is not within dropdown children", %{
    conn: conn,
    account: account,
    identity: identity
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/actors")

    refute Enum.empty?(
             html
             |> Floki.parse_fragment!()
             |> Floki.find("ul#dropdown-settings.hidden")
           )
  end

  test "shows dropdown when path is within dropdown children", %{
    conn: conn,
    account: account,
    identity: identity
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/settings/dns")

    assert Enum.empty?(
             html
             |> Floki.parse_fragment!()
             |> Floki.find("ul#dropdown-settings.hidden")
           )

    refute Enum.empty?(html |> Floki.parse_fragment!() |> Floki.find("ul#dropdown-settings"))
  end

  test "renders proper active sidebar item class for actors", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/actors")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/actors']")

    assert String.trim(Floki.text(item)) == "Actors"
  end

  test "renders proper active sidebar item class for groups", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/groups")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/groups']")

    assert String.trim(Floki.text(item)) == "Groups"
  end

  test "renders proper active sidebar item class for clients", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/clients")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/clients']")

    assert String.trim(Floki.text(item)) == "Clients"
  end

  test "renders proper active sidebar item class for sites", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/sites")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/sites']")

    assert String.trim(Floki.text(item)) == "Sites"
  end

  test "renders proper active sidebar item class for relays", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/relay_groups")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/relay_groups']")

    assert String.trim(Floki.text(item)) == "Relays"
  end

  # test "renders proper active sidebar item class for resources", %{
  #   account: account,
  #   identity: identity,
  #   conn: conn
  # } do
  #   {:ok, _lv, html} = conn |> authorize_conn(identity) |> live( ~p"/#{account}/resources")
  #   assert item = html |> Floki.parse_fragment!() |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/resources']")
  #   assert String.trim(Floki.text(item)) == "Resources"
  # end

  test "renders proper active sidebar item class for policies", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/policies")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/policies']")

    assert String.trim(Floki.text(item)) == "Policies"
  end

  test "renders proper active sidebar item class for account", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/settings/account")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/settings/account']")

    assert String.trim(Floki.text(item)) == "Account"
  end

  test "renders proper active sidebar item class for identity providers", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn |> authorize_conn(identity) |> live(~p"/#{account}/settings/identity_providers")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/settings/identity_providers']")

    assert String.trim(Floki.text(item)) == "Identity Providers"
  end

  test "renders proper active sidebar item class for new OIDC identity provider", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      live(
        authorize_conn(conn, identity),
        ~p"/#{account}/settings/identity_providers/openid_connect/new"
      )

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/settings/identity_providers']")

    assert String.trim(Floki.text(item)) == "Identity Providers"
  end

  test "renders proper active sidebar item class for dns", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(identity) |> live(~p"/#{account}/settings/dns")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/settings/dns']")

    assert String.trim(Floki.text(item)) == "DNS"
  end
end
