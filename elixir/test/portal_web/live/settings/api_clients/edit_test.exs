defmodule PortalWeb.Live.Settings.ApiClients.EditTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    api_client = api_client_fixture(account: account)
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor,
      api_client: api_client
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    api_client: api_client,
    conn: conn
  } do
    path = ~p"/#{account}/settings/api_clients/#{api_client}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "raises NoResultsError when API Client is deleted", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    Repo.delete!(api_client)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")
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
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ api_client.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    form = form(lv, "form[phx-submit=submit]")

    assert find_inputs(form) == [
             "actor[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    lv
    |> form("form[phx-submit=submit]", actor: %{name: "Test"})
    |> validate_change(%{actor: %{name: String.duplicate("a", 300)}}, fn form, _html ->
      errors = form_validation_errors(form)
      assert "should be at most 255 character(s)" in errors["actor[name]"]
    end)
    |> validate_change(%{actor: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "actor[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    attrs = %{name: String.duplicate("a", 300)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    errors =
      lv
      |> form("form[phx-submit=submit]", actor: attrs)
      |> render_submit()
      |> form_validation_errors()

    assert "should be at most 255 character(s)" in errors["actor[name]"]
  end

  test "updates an api client on valid attrs", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    attrs = %{name: "Updated API Client Name"}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    lv
    |> form("form[phx-submit=submit]", actor: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/settings/api_clients/#{api_client}")

    assert updated = Repo.get_by(Portal.Actor, id: api_client.id)
    assert updated.name == attrs.name
  end
end
