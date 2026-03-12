defmodule PortalWeb.Live.Sites.EditTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    site = site_fixture(account: account)

    %{
      account: account,
      actor: actor,
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
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders not found error when site is deleted", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    Repo.delete!(site)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/edit")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ site.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/edit")

    form = form(lv, "form[phx-submit]")

    assert find_inputs(form) == [
             "site[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    attrs = valid_site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/edit")

    lv
    |> form("form[phx-submit]", site: attrs)
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
    actor: actor,
    site: site,
    conn: conn
  } do
    other_site = site_fixture(account: account)
    attrs = %{name: other_site.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/edit")

    assert lv
           |> form("form[phx-submit]", site: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "site[name]" => ["has already been taken"]
           }
  end

  test "updates a site on valid attrs", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    attrs = valid_site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/edit")

    lv
    |> form("form[phx-submit]", site: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/sites/#{site}")

    assert updated_site = Repo.get_by(Portal.Site, id: site.id)
    assert updated_site.name == attrs.name
  end
end
