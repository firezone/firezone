defmodule PortalWeb.Live.Resources.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.PolicyFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/resources"

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
      |> live(~p"/#{account}/resources")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
  end

  test "renders add resource button", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/resources/new']")

    assert Floki.text(button) =~ "Add Resource"
  end

  test "renders resources table", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    site = site_fixture(account: account)
    resource = resource_fixture(account: account, site: site)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    Enum.each(resource_rows, fn row ->
      assert row["name"] =~ resource.name
      assert row["address"] =~ resource.address
      assert row["site"] =~ site.name
    end)
  end

  test "sort alphabetically by name ASC by default", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    resource5 = resource_fixture(account: account, name: "Resource 5")
    resource4 = resource_fixture(account: account, name: "Resource 4")
    resource3 = resource_fixture(account: account, name: "Resource 3")
    resource2 = resource_fixture(account: account, name: "Resource 2")
    resource1 = resource_fixture(account: account, name: "Resource 1")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    assert Enum.at(resource_rows, 0)["name"] =~ resource1.name
    assert Enum.at(resource_rows, 1)["name"] =~ resource2.name
    assert Enum.at(resource_rows, 2)["name"] =~ resource3.name
    assert Enum.at(resource_rows, 3)["name"] =~ resource4.name
    assert Enum.at(resource_rows, 4)["name"] =~ resource5.name
  end

  test "renders policies count peek", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    site = site_fixture(account: account)
    resource = resource_fixture(account: account, site: site)

    policies =
      for _ <- 1..3 do
        policy_fixture(account: account, resource: resource)
      end

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    Enum.each(resource_rows, fn row ->
      assert row["policies"] =~ "#{length(policies)} policies"
    end)
  end

  test "renders Internet Resource section if enabled", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account = update_account(account, features: %{internet_resource: true})
    internet_site = internet_site_fixture(account: account)
    internet_resource_fixture(account: account, site: internet_site)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources")

    path = ~p"/#{account}/resources/internet"

    assert {_, {:live_redirect, %{to: ^path}}} =
             lv
             |> element("#view-internet-resource")
             |> render_click()
  end

  test "does not render Internet Resource section if disabled", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    internet_site = internet_site_fixture(account: account)
    internet_resource_fixture(account: account, site: internet_site)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/resources")

    refute html =~ "view-internet-resource"
    refute html =~ "View Internet Resource"
  end

  describe "handle_info/2" do
    test "shows reload button when resource is created", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      refute html =~ "resources-reload-btn"

      resource = resource_fixture(account: account)

      Portal.Changes.Hooks.Resources.on_insert(0, %{
        "id" => resource.id,
        "account_id" => account.id
      })

      wait_for(fn ->
        assert has_element?(lv, "#resources-reload-btn")
      end)
    end

    test "shows reload button when resource is deleted", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      refute html =~ "resources-reload-btn"

      Portal.Changes.Hooks.Resources.on_delete(0, %{
        "id" => resource.id,
        "account_id" => account.id
      })

      wait_for(fn ->
        assert has_element?(lv, "#resources-reload-btn")
      end)
    end
  end
end
