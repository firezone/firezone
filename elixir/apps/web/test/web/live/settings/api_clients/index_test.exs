defmodule Web.Live.Settings.ApiClients.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "redirects to beta page when feature not enabled for account", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    features = Map.from_struct(account.features)
    attrs = %{features: %{features | rest_api: false}}

    account = Fixtures.Accounts.update_account(account, attrs)

    assert {:error, {:live_redirect, %{to: path, flash: _}}} =
             conn
             |> authorize_conn(identity)
             |> live(~p"/#{account}/settings/api_clients")

    assert path == ~p"/#{account}/settings/api_clients/beta"
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
  end

  test "renders add api client button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/settings/api_clients/new']")

    assert Floki.text(button) =~ "Add API Client"
  end

  test "renders table with multiple api clients", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    api_client_2 = Fixtures.Actors.create_actor(type: :api_client, account: account)
    api_client_3 = Fixtures.Actors.create_actor(type: :api_client, account: account)

    Fixtures.Actors.disable(api_client_2)
    Fixtures.Tokens.create_api_client_token(account: account, actor: api_client_3)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
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
