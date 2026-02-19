defmodule PortalWeb.Live.Clients.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.ClientSessionFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/clients"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders breadcrumbs item", %{account: account, actor: actor, conn: conn} do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Clients"
  end

  test "renders empty table when there are no clients", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients")

    assert html =~ "No Actors have signed in from any Client"
  end

  test "renders clients table with session info", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    client = client_fixture(account: account, actor: actor)
    _session = client_session_fixture(account: account, actor: actor, client: client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients")

    lv
    |> element("#clients")
    |> render()
    |> table_to_map()
    |> with_table_row("name", client.name, fn row ->
      assert row["version"] =~ "1.3.0"
      assert row["last started"]
    end)
  end

  test "renders clients without sessions", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    client = client_fixture(account: account, actor: actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients")

    lv
    |> element("#clients")
    |> render()
    |> table_to_map()
    |> with_table_row("name", client.name, fn row ->
      assert row["name"] == client.name
    end)
  end

  # Regression test for: clients index page resets when clicking "next page"
  # when the last client on a page has no sessions (left lateral join returns null
  # for latest_session_inserted_at, which was incorrectly rejected as invalid cursor).
  test "paginates correctly when clients have no sessions", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    # Create 11 clients with no sessions (default page size is 10).
    # With DESC NULLS LAST ordering, these null-session clients sort last.
    # Page 1 will have 10 of them, creating a next_page_cursor with a nil
    # latest_session_inserted_at value.
    for _ <- 1..11, do: client_fixture(account: account, actor: actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients")

    # The paginator is rendered outside the <table> element, so we render the
    # full live view to find the pagination buttons.
    full_html = render(lv)

    # Verify a next page exists (there are 11 clients, page size is 10)
    assert [next_button] =
             full_html
             |> Floki.parse_fragment!()
             |> Floki.find("button[phx-click='paginate']:not([disabled])")

    assert Floki.attribute(next_button, "phx-value-cursor") != [nil]

    # Click next page — previously this would reset the page with
    # "The page was reset due to invalid pagination cursor."
    lv |> element("button[phx-click='paginate']:not([disabled])") |> render_click()

    # Assert the page did NOT reset (no error flash about invalid cursor)
    refute render(lv) =~ "invalid pagination cursor"
  end
end
