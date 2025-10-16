defmodule Web.Live.Clients.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      client: client
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    client: client,
    conn: conn
  } do
    path = ~p"/#{account}/clients/#{client}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when client is deleted", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    client = Fixtures.Clients.delete_client(client)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Clients"
    assert breadcrumbs =~ client.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "client[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    attrs = Fixtures.Clients.client_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}/edit")

    lv
    |> form("form", client: attrs)
    |> validate_change(%{client: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "client[name]" => ["should be at most 255 character(s)"]
             }
    end)
    |> validate_change(%{client: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "client[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    attrs = %{name: String.duplicate("a", 256)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}/edit")

    assert lv
           |> form("form", client: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "client[name]" => ["should be at most 255 character(s)"]
           }
  end

  test "creates a new client on valid attrs", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    attrs = Fixtures.Clients.client_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}/edit")

    lv
    |> form("form", client: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/clients/#{client}")

    assert client = Repo.get_by(Domain.Clients.Client, id: client.id)
    assert client.name == attrs.name
  end
end
