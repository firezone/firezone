defmodule Web.Live.Sites.NewTest do
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
    path = ~p"/#{account}/sites/new"

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
      |> live(~p"/#{account}/sites/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
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
      |> live(~p"/#{account}/sites/new")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "group[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = Fixtures.Sites.site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    lv
    |> form("form", site: attrs)
    |> validate_change(%{site: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "group[name]" => ["should be at most 64 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    other_gateway = Fixtures.Sites.create_site(account: account)
    attrs = %{name: other_gateway.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    assert lv
           |> form("form", site: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "group[name]" => ["has already been taken"]
           }
  end

  test "creates a new group on valid attrs and redirects when gateway is connected", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = Fixtures.Sites.site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    lv
    |> form("form", site: attrs)
    |> render_submit()

    group =
      Repo.get_by(Domain.Site, name: attrs.name)
      |> Repo.preload(:tokens)

    assert assert_redirect(lv, ~p"/#{account}/sites/#{group}")
  end

  test "renders error when sites limit is reached", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Sites.create_site(account: account)

    {:ok, account} =
      Fixtures.Accounts.update_account(account, %{
        limits: %{
          sites_count: 1
        }
      })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    attrs =
      Fixtures.Sites.site_attrs()
      |> Map.take([:name])

    html =
      lv
      |> form("form", site: attrs)
      |> render_submit()

    assert html =~ "You have reached the maximum number of"
    assert html =~ "sites allowed by your subscription plan."
  end
end
