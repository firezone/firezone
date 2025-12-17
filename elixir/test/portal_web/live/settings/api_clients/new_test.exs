defmodule PortalWeb.Live.Settings.ApiClients.NewTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    conn: conn
  } do
    path = ~p"/#{account}/settings/api_clients/new"

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
             |> live(~p"/#{account}/settings/api_clients/new")

    assert path == ~p"/#{account}/settings/api_clients/beta"
  end

  test "redirects to index when API clients limit is reached", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account = update_account(account, %{limits: %{api_clients_count: 1}})
    _api_client = api_client_fixture(account: account)

    assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
             conn
             |> authorize_conn(actor)
             |> live(~p"/#{account}/settings/api_clients/new")

    assert path == ~p"/#{account}/settings/api_clients"
    assert flash["error"] =~ "maximum number of API clients"
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ "Add"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/new")

    form = form(lv, "form[phx-submit=submit]")

    assert find_inputs(form) == ["actor[name]"]
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/new")

    lv
    |> form("form[phx-submit=submit]", actor: %{name: "Test"})
    |> validate_change(%{actor: %{name: String.duplicate("a", 555)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "actor[name]" => ["should be at most 255 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/new")

    assert lv
           |> form("form[phx-submit=submit]", actor: %{})
           |> render_submit()
           |> form_validation_errors() == %{
             "actor[name]" => ["can't be blank"]
           }
  end

  test "creates a new actor on valid attrs", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    attrs = %{
      name: "Test API Client"
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/new")

    lv
    |> form("form[phx-submit=submit]", actor: attrs)
    |> render_submit()

    assert api_client = Repo.get_by(Portal.Actor, name: attrs.name)

    assert_redirect(lv, ~p"/#{account}/settings/api_clients/#{api_client}/new_token")
  end

  test "redirects when limit is reached during submit", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account = update_account(account, %{limits: %{api_clients_count: 1}})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/new")

    # Create an API client after loading the page to simulate a race condition
    _api_client = api_client_fixture(account: account)

    lv
    |> form("form[phx-submit=submit]", actor: %{name: "Test API Client"})
    |> render_submit()

    assert_redirect(lv, ~p"/#{account}/settings/api_clients")
  end
end
