defmodule Web.Live.Clients.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
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

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
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
    online_client_actor = Fixtures.Actors.create_actor(account: account, type: :service_account)

    online_client_identity =
      Fixtures.Auth.create_identity(account: account, actor: online_client_actor)

    online_client =
      Fixtures.Clients.create_client(
        account: account,
        actor: online_client_actor,
        identity: online_client_identity
      )

    offline_client = Fixtures.Clients.create_client(account: account)

    client_token =
      Fixtures.Tokens.create_client_token(
        account: account,
        actor: online_client_actor,
        identity: online_client_identity
      )

    :ok = Domain.Presence.Clients.connect(online_client, client_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients")

    lv
    |> element("#clients")
    |> render()
    |> table_to_map()
    |> with_table_row("name", online_client.name, fn row ->
      assert row["version"] =~ "1.3.0"
      assert row["status"] == "Online"
      name = Repo.preload(online_client, :actor).actor.name
      assert row["user"] =~ name
      assert row[""] =~ "Apple iOS"
      assert row["last started"]
      assert row["created"]
    end)
    |> with_table_row("name", offline_client.name, fn row ->
      assert row["version"] =~ "1.3.0"
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
    client_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    client =
      Fixtures.Clients.create_client(account: account, actor: actor, identity: client_identity)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients")

    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Presence.Clients.Actor.subscribe(client.actor_id)

    client_token =
      Fixtures.Tokens.create_client_token(
        account: account,
        actor: actor,
        identity: client_identity
      )

    assert Domain.Presence.Clients.connect(client, client_token.id) == :ok
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
