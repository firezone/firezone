defmodule PortalWeb.Live.Sites.NewTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    %{
      account: account,
      actor: actor
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
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/new")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
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
      |> live(~p"/#{account}/sites/new")

    form = form(lv, "form[phx-submit]")

    assert find_inputs(form) == [
             "site[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    attrs = valid_site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/new")

    lv
    |> form("form[phx-submit]", site: attrs)
    |> validate_change(%{site: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "site[name]" => ["should be at most 64 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    other_site = site_fixture(account: account)
    attrs = %{name: other_site.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/new")

    assert lv
           |> form("form[phx-submit]", site: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "site[name]" => ["has already been taken"]
           }
  end

  test "creates a new site on valid attrs and redirects to site", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    attrs = valid_site_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/new")

    lv
    |> form("form[phx-submit]", site: attrs)
    |> render_submit()

    site = Repo.get_by(Portal.Site, name: attrs.name)
    assert site
    assert assert_redirect(lv, ~p"/#{account}/sites/#{site}")
  end

  test "renders error when sites limit is reached", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    site_fixture(account: account)
    update_account(account, limits: %{sites_count: 1})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/new")

    attrs = valid_site_attrs() |> Map.take([:name])

    html =
      lv
      |> form("form[phx-submit]", site: attrs)
      |> render_submit()

    assert html =~ "You have reached the maximum number of"
    assert html =~ "sites allowed by your subscription plan."
  end
end
