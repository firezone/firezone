defmodule Web.Live.Settings.ApiClient.NewTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      identity: identity
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "redirects to beta page when feature not enabled for account", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    features = Map.from_struct(account.features)
    attrs = %{features: %{features | rest_api: false}}

    {:ok, account} = Domain.Accounts.update_account(account, attrs)

    assert {:error, {:live_redirect, %{to: path, flash: _}}} =
             conn
             |> authorize_conn(identity)
             |> live(~p"/#{account}/settings/api_clients/new")

    assert path == ~p"/#{account}/settings/api_clients/beta"
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ "Add"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/new")

    form = form(lv, "form")

    assert find_inputs(form) == ["actor[name]"]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = Fixtures.Actors.actor_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/new")

    lv
    |> form("form", actor: attrs)
    |> validate_change(%{actor: %{name: String.duplicate("a", 555)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "actor[name]" => ["should be at most 512 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/new")

    assert lv
           |> form("form", actor: %{})
           |> render_submit()
           |> form_validation_errors() == %{
             "actor[name]" => ["can't be blank"]
           }
  end

  test "creates a new actor on valid attrs", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      name: Fixtures.Actors.actor_attrs().name
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/new")

    lv
    |> form("form", actor: attrs)
    |> render_submit()

    assert api_client = Repo.get_by(Domain.Actors.Actor, name: attrs.name)

    assert_redirect(lv, ~p"/#{account}/settings/api_clients/#{api_client}/new_token")
  end
end
