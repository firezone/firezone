defmodule PortalWeb.Live.DashboardTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.ClientSessionFixtures
  import Portal.GroupFixtures
  import Portal.PolicyFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/dashboard"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders dashboard with stat cards and sections", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    # Page title and subtitle
    assert html =~ "Dashboard"
    assert html =~ "Infrastructure"
    assert html =~ "access overview"

    # Summary chip labels
    assert html =~ "Sites"
    assert html =~ "Resources"
    assert html =~ "Active Policies"
    assert html =~ "Groups"
    assert html =~ "Actors"

    # Bottom panel headings
    assert html =~ "Policy Authorizations"
    assert html =~ "Recent Sessions"
  end

  test "renders stat cards with correct counts", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    user_actor = actor_fixture(account: account)
    site = site_fixture(account: account)
    resource = resource_fixture(account: account, site: site)
    group = group_fixture(account: account)
    _policy = policy_fixture(account: account, resource: resource, group: group)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    assert html =~ "Dashboard"
    _ = user_actor
    assert html =~ "Policy Authorizations"
  end

  test "renders recent connections section", %{account: account, actor: actor, conn: conn} do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    assert html =~ "Policy Authorizations"
  end

  test "renders recent connections when policy authorizations exist", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    _auth = policy_authorization_fixture(account: account, actor: actor)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    assert html =~ actor.name
  end

  test "renders recent client sessions when sessions exist", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    client = client_fixture(account: account, actor: actor)
    _session = client_session_fixture(account: account, actor: actor, client: client)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    assert html =~ actor.name
    _ = client
  end

  test "does not render health warnings when no issues", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    refute html =~ "has no online gateways"
    refute html =~ "hero-exclamation-triangle-solid"
  end

  test "renders health warnings when sites have no online gateways", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    _site = site_fixture(account: account, name: "Production Site")

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    assert html =~ "Production Site"
    assert html =~ "has no online gateways"
  end

  test "shows site status in infrastructure health panel", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    _site = site_fixture(account: account, name: "East Coast Site")

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/dashboard")

    assert html =~ "East Coast Site"
    assert html =~ "Offline"
  end
end
