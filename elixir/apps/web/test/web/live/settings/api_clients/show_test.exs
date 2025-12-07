defmodule Web.Live.Settings.ApiClients.ShowTest do
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

  test "redirects to sign in page for unauthorized user", %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

    path = ~p"/#{account}/settings/api_clients/#{actor}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "raises NotFoundError for deleted actor", %{conn: conn} do
    account = Fixtures.Accounts.create_account()

    api_client =
      Fixtures.Actors.create_actor(type: :api_client, account: account)
      |> Fixtures.Actors.delete()

    auth_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    auth_identity = Fixtures.Auth.create_identity(account: account, actor: auth_actor)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(auth_identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")
    end
  end

  test "renders breadcrumbs item", %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ api_client.name
  end

  test "renders api client details", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert html =~ "API Client"

    expected_date = Cldr.DateTime.Formatter.date(api_client.inserted_at, 1, "en", Web.CLDR, [])

    assert lv
           |> element("#api-client")
           |> render()
           |> vertical_table_to_map() == %{
             "name" => api_client.name,
             "created" => expected_date
           }
  end

  test "allows creating tokens", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    lv
    |> element("a:first-child", "Create Token")
    |> render_click()

    assert_redirect(lv, ~p"/#{account}/settings/api_clients/#{api_client}/new_token")
  end

  test "allows editing api clients", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert lv
           |> element("a", "Edit API Client")
           |> render_click() ==
             {:error,
              {:live_redirect,
               %{to: ~p"/#{account}/settings/api_clients/#{api_client}/edit", kind: :push}}}
  end

  test "allows deleting actors", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    lv
    |> element("button[type=submit]", "Delete API Client")
    |> render_click()

    assert_redirect(lv, ~p"/#{account}/settings/api_clients")
    refute Repo.get(Domain.Actor, api_client.id)
  end

  test "allows disabling api clients", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    refute has_element?(lv, "button", "Enable API Client")

    assert lv
           |> element("button[type=submit]", "Disable")
           |> render_click()
           |> Floki.parse_fragment!()
           |> Floki.find(".flash-info")
           |> element_to_text() =~ "API Client was disabled."

    assert Repo.get(Domain.Actor, api_client.id).disabled_at
  end

  test "allows enabling api clients", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    api_client = Fixtures.Actors.disable(api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    refute has_element?(lv, "button[type=submit]", "Disable API Client")

    assert lv
           |> element("button[type=submit]", "Enable")
           |> render_click()
           |> Floki.parse_fragment!()
           |> Floki.find(".flash-info")
           |> element_to_text() =~ "API Client was enabled."

    refute Repo.get(Domain.Actor, api_client.id).disabled_at
  end

  test "renders api client tokens", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)
    token = Fixtures.Tokens.create_api_client_token(account: account, actor: api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    [row1] =
      lv
      |> element("#tokens")
      |> render()
      |> table_to_map()

    assert row1["name"] == token.name
    assert row1["expires at"]
    assert row1["last used"] == "Never"
    assert row1["actions"] =~ "Revoke"
  end

  test "allows revoking tokens", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)
    token = Fixtures.Tokens.create_api_client_token(account: account, actor: api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert lv
           |> element("td button[type=submit]", "Revoke")
           |> render_click()

    assert lv
           |> element("#tokens")
           |> render()
           |> table_to_map() == []

    refute Repo.get_by(Domain.Token, id: token.id)
  end

  test "allows revoking all tokens", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)
    token = Fixtures.Tokens.create_api_client_token(account: account, actor: api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert lv
           |> element("#tokens")
           |> render()
           |> table_to_map() != []

    assert lv
           |> element("button[type=submit]", "Revoke All")
           |> render_click()

    assert lv
           |> element("#tokens")
           |> render()
           |> table_to_map() == []

    refute Repo.get_by(Domain.Token, id: token.id)
  end
end
