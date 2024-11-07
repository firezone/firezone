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

    assert html =~ "No Actors have signed in from any Client"
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
      assert row[""] =~ "Apple iOS"
      assert row["last started"]
      assert row["created"]
    end)
    |> with_table_row("name", offline_client.name, fn row ->
      assert row["status"] == "Offline"
      name = Repo.preload(offline_client, :actor).actor.name
      assert row["user"] =~ name
      assert row[""]
      assert row["last started"]
      assert row["created"]
    end)
  end

  test "updates clients table using presence events", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    actor = Fixtures.Actors.create_actor(account: account)
    client = Fixtures.Clients.create_client(account: account, actor: actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients")

    Domain.Config.put_env_override(:test_pid, self())
    Domain.Clients.subscribe_to_clients_presence_for_actor(actor)
    assert Domain.Clients.connect_client(client) == :ok
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:actor_clients:" <> _}
    assert_receive {:live_table_reloaded, "clients"}, 250

    [row] =
      lv
      |> element("#clients")
      |> render()
      |> table_to_map()

    assert row["status"] == "Online"
  end
end
