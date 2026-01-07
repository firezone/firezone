defmodule PortalWeb.Live.Settings.ApiClients.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    api_client = api_client_fixture(account: account)

    %{
      account: account,
      actor: actor,
      api_client: api_client
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/api_clients"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "redirects to beta page when feature not enabled for account", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account = update_account(account, %{features: %{rest_api: false}})

    assert {:error, {:live_redirect, %{to: path, flash: _}}} =
             conn
             |> authorize_conn(actor)
             |> live(~p"/#{account}/settings/api_clients")

    assert path == ~p"/#{account}/settings/api_clients/beta"
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
  end

  test "renders add api client button", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/settings/api_clients/new']")

    assert Floki.text(button) =~ "Add API Client"
  end

  test "renders table with multiple api clients", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    api_client_2 = api_client_fixture(account: account)
    api_client_3 = api_client_fixture(account: account)

    # Disable api_client_2
    api_client_2 =
      api_client_2
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

    api_token_fixture(account: account, actor: api_client_3)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients")

    rows =
      lv
      |> element("#actors")
      |> render()
      |> table_to_map()

    assert length(rows) == 3

    rows
    |> with_table_row("name", api_client.name, fn row ->
      assert row["status"] =~ "Active"
    end)
    |> with_table_row("name", api_client_2.name, fn row ->
      assert row["status"] =~ "Disabled"
    end)
    |> with_table_row("name", api_client_3.name, fn row ->
      assert row["status"] =~ "Active"
    end)
  end
end
