defmodule PortalWeb.Live.Settings.ApiClients.ShowTest do
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

  test "redirects to sign in page for unauthorized user", %{conn: conn} do
    account = account_fixture()
    api_client = api_client_fixture(account: account)

    path = ~p"/#{account}/settings/api_clients/#{api_client}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "raises NoResultsError for deleted actor", %{conn: conn} do
    account = account_fixture()
    api_client = api_client_fixture(account: account)
    Repo.delete!(api_client)

    auth_actor = admin_actor_fixture(account: account)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(auth_actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ api_client.name
  end

  test "renders api client details", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert html =~ "API Client"

    expected_date =
      Cldr.DateTime.Formatter.date(api_client.inserted_at, 1, "en", Portal.CLDR, [])

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
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    lv
    |> element("a:first-child", "Create Token")
    |> render_click()

    assert_redirect(lv, ~p"/#{account}/settings/api_clients/#{api_client}/new_token")
  end

  test "allows editing api clients", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
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
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    lv
    |> element("button[type=submit]", "Delete API Client")
    |> render_click()

    assert_redirect(lv, ~p"/#{account}/settings/api_clients")
    refute Repo.get_by(Portal.Actor, id: api_client.id, account_id: api_client.account_id)
  end

  test "allows disabling api clients", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    refute has_element?(lv, "button", "Enable API Client")

    lv
    |> element("button[type=submit]", "Disable")
    |> render_click()

    assert Repo.get_by(Portal.Actor, id: api_client.id, account_id: api_client.account_id).disabled_at
  end

  test "allows enabling api clients", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    api_client =
      api_client
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    refute has_element?(lv, "button[type=submit]", "Disable API Client")

    lv
    |> element("button[type=submit]", "Enable")
    |> render_click()

    refute Repo.get_by(Portal.Actor, id: api_client.id, account_id: api_client.account_id).disabled_at
  end

  test "renders api client tokens", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    api_client = api_client_fixture(account: account)
    token = api_token_fixture(account: account, actor: api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
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
    actor: actor,
    conn: conn
  } do
    api_client = api_client_fixture(account: account)
    token = api_token_fixture(account: account, actor: api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}")

    assert lv
           |> element("td button[type=submit]", "Revoke")
           |> render_click()

    assert lv
           |> element("#tokens")
           |> render()
           |> table_to_map() == []

    refute Repo.get_by(Portal.APIToken, id: token.id)
  end

  test "allows revoking all tokens", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    api_client = api_client_fixture(account: account)
    token = api_token_fixture(account: account, actor: api_client)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
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

    refute Repo.get_by(Portal.APIToken, id: token.id)
  end
end
