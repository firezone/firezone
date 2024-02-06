defmodule Web.Live.Clients.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/clients"

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
      |> live(~p"/#{account}/clients")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Clients"
  end

  test "renders empty table when there are no clients", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients")

    assert html =~ "No clients to display"
  end

  test "renders clients table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    online_client = Fixtures.Clients.create_client(account: account)
    offline_client = Fixtures.Clients.create_client(account: account)

    :ok = Domain.Clients.connect_client(online_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients")

    lv
    |> element("#clients")
    |> render()
    |> table_to_map()
    |> with_table_row("name", online_client.name, fn row ->
      assert row["status"] == "Online"
      name = Repo.preload(online_client, :actor).actor.name
      assert row["user"] =~ name
    end)
    |> with_table_row("name", offline_client.name, fn row ->
      assert row["status"] == "Offline"
      name = Repo.preload(offline_client, :actor).actor.name
      assert row["user"] =~ name
    end)
  end
end
