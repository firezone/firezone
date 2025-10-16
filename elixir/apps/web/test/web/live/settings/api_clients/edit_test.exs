defmodule Web.Live.Settings.ApiClients.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(actor: actor, account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when API Client is deleted", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    api_client = Fixtures.Actors.delete(api_client)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ api_client.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "actor[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    attrs = Fixtures.Actors.actor_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    lv
    |> form("form", actor: attrs)
    |> validate_change(%{actor: %{name: String.duplicate("a", 555)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "actor[name]" => ["should be at most 512 character(s)"]
             }
    end)
    |> validate_change(%{actor: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "actor[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    attrs = %{name: String.duplicate("a", 555)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    assert lv
           |> form("form", actor: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "actor[name]" => ["should be at most 512 character(s)"]
           }
  end

  test "updates an api client on valid attrs", %{
    account: account,
    identity: identity,
    api_client: api_client,
    conn: conn
  } do
    attrs = %{name: Fixtures.Actors.actor_attrs().name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

    lv
    |> form("form", actor: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/settings/api_clients/#{api_client}")

    assert actor = Repo.get_by(Domain.Actors.Actor, id: api_client.id)
    assert actor.name == attrs.name
  end
end
