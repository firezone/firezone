defmodule PortalWeb.SidebarTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    %{
      account: account,
      actor: actor
    }
  end

  test "hides dropdown when path is not within dropdown children", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/actors")

    refute Enum.empty?(
             html
             |> Floki.parse_fragment!()
             |> Floki.find("ul#dropdown-settings.hidden")
           )
  end

  test "shows dropdown when path is within dropdown children", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/dns")

    assert Enum.empty?(
             html
             |> Floki.parse_fragment!()
             |> Floki.find("ul#dropdown-settings.hidden")
           )

    refute Enum.empty?(html |> Floki.parse_fragment!() |> Floki.find("ul#dropdown-settings"))
  end

  test "renders proper active sidebar item class for actors", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/actors")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/actors']")

    assert String.trim(Floki.text(item)) == "Actors"
  end

  test "renders proper active sidebar item class for groups", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/groups")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/groups']")

    assert String.trim(Floki.text(item)) == "Groups"
  end

  test "renders proper active sidebar item class for clients", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/clients")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/clients']")

    assert String.trim(Floki.text(item)) == "Clients"
  end

  test "renders proper active sidebar item class for sites", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/sites']")

    assert String.trim(Floki.text(item)) == "Sites"
  end

  test "renders proper active sidebar item class for policies", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/policies")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/policies']")

    assert String.trim(Floki.text(item)) == "Policies"
  end

  test "renders proper active sidebar item class for account settings", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/account")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/settings/account']")

    assert String.trim(Floki.text(item)) == "Account"
  end

  test "renders proper active sidebar item class for dns", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/dns")

    assert item =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a.bg-neutral-50[href='/#{account.slug}/settings/dns']")

    assert String.trim(Floki.text(item)) == "DNS"
  end
end
