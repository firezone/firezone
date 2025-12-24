defmodule Web.Live.Actors.ServiceAccount.NewTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    provider = Fixtures.Auth.create_email_provider(account: account)
    identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

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
    path = ~p"/#{account}/actors/service_accounts/new"

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
      |> live(~p"/#{account}/actors/service_accounts/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Actors"
    assert breadcrumbs =~ "Add"
    assert breadcrumbs =~ "Service Account"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/service_accounts/new")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "actor[name]"
           ]
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
      |> live(~p"/#{account}/actors/service_accounts/new")

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
      |> live(~p"/#{account}/actors/service_accounts/new")

    assert lv
           |> form("form", actor: %{})
           |> render_submit()
           |> form_validation_errors() == %{
             "actor[name]" => ["can't be blank"]
           }
  end

  test "renders changeset errors when seats count is exceeded", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, account} =
      Fixtures.Accounts.update_account(account, %{
        limits: %{
          service_accounts_count: 1
        }
      })

    Fixtures.Actors.create_actor(type: :service_account, account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/service_accounts/new")

    attrs =
      Fixtures.Actors.actor_attrs()
      |> Map.take([:name])

    html =
      lv
      |> form("form", actor: attrs)
      |> render_submit()

    assert html =~ "You have reached the maximum number of"
    assert html =~ "service accounts allowed by your subscription plan"
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
      |> live(~p"/#{account}/actors/service_accounts/new")

    lv
    |> form("form", actor: attrs)
    |> render_submit()

    assert actor = Repo.get_by(Domain.Actor, name: attrs.name)
    assert actor.type == :service_account

    assert_redirect(lv, ~p"/#{account}/actors/service_accounts/#{actor}/new_identity")
  end
end
