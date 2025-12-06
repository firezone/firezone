defmodule Web.Live.Sites.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    site = Fixtures.Sites.create_site(account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
      site: site
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    site: site,
    conn: conn
  } do
    path = ~p"/#{account}/sites/#{site}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when site is deleted", %{
    account: account,
    identity: identity,
    site: site,
    conn: conn
  } do
    {:ok, site} = Fixtures.Sites.delete_site(site)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    site: site,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ site.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    site: site,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "site[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    site: site,
    conn: conn
  } do
    attrs = Fixtures.Sites.site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}/edit")

    lv
    |> form("form", site: attrs)
    |> validate_change(%{site: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "site[name]" => ["should be at most 64 character(s)"]
             }
    end)
    |> validate_change(%{site: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "site[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    site: site,
    conn: conn
  } do
    other_site = Fixtures.Sites.create_site(account: account)
    attrs = %{name: other_site.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}/edit")

    assert lv
           |> form("form", site: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "site[name]" => ["has already been taken"]
           }
  end

  test "updates a site on valid attrs", %{
    account: account,
    identity: identity,
    site: site,
    conn: conn
  } do
    attrs = Fixtures.Sites.site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{site}/edit")

    lv
    |> form("form", site: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/sites/#{site}")

    assert site = Repo.get(Domain.Site, site.id)
    assert site.name == attrs.name
  end
end
