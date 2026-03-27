defmodule PortalWeb.Live.Clients.EditTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    client = client_fixture(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
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
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders not found error when client is deleted", %{
    account: account,
    actor: actor,
    client: client,
    conn: conn
  } do
    Repo.delete!(client)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients/#{client}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    client: client,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients/#{client}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Clients"
    assert breadcrumbs =~ client.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    client: client,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients/#{client}/edit")

    form = form(lv, "form[phx-submit]")

    assert find_inputs(form) == [
             "client[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    client: client,
    conn: conn
  } do
    attrs = valid_client_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients/#{client}/edit")

    lv
    |> form("form[phx-submit]", client: attrs)
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
    actor: actor,
    client: client,
    conn: conn
  } do
    attrs = %{name: String.duplicate("a", 256)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients/#{client}/edit")

    assert lv
           |> form("form[phx-submit]", client: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "client[name]" => ["should be at most 255 character(s)"]
           }
  end

  test "updates client on valid attrs", %{
    account: account,
    actor: actor,
    client: client,
    conn: conn
  } do
    attrs = valid_client_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/clients/#{client}/edit")

    lv
    |> form("form[phx-submit]", client: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/clients/#{client}")

    assert updated_client = Repo.get_by(Portal.Device, id: client.id, type: :client)
    assert updated_client.name == attrs.name
  end
end
