defmodule PortalWeb.SitesTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Repo, Resource, Site}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GatewayFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/sites"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "renders site list page", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites")

      assert html =~ "Sites"
      assert html =~ site.name
    end

    test "opens the new site panel, validates, and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites")

      render_click(lv, "open_new_site_panel")
      assert_patch(lv, ~p"/#{account}/sites/new")
      html = render(lv)
      assert html =~ "New Site"
      assert html =~ "Create Site"

      html =
        lv
        |> form("[phx-submit='new_site_submit']", site: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"

      render_click(lv, "close_new_site_panel")
      assert_patch(lv, ~p"/#{account}/sites")
      refute render(lv) =~ "Create Site"
    end

    test "navigating directly to /sites/new opens the new site panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/new")

      assert html =~ "New Site"
      assert html =~ "Create Site"
    end

    test "creates a site and opens its detail panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites")

      render_click(lv, "open_new_site_panel")
      assert_patch(lv, ~p"/#{account}/sites/new")

      html =
        lv
        |> form("[phx-submit='new_site_submit']",
          site: %{name: "Chicago POP", health_threshold: 3}
        )
        |> render_submit()

      site = Repo.get_by!(Site, account_id: account.id, name: "Chicago POP")

      assert html =~ "Site Chicago POP created successfully."
      assert html =~ "Chicago POP"
      assert_patch(lv, ~p"/#{account}/sites/#{site.id}")
    end
  end

  describe ":show action" do
    test "renders site detail panel with site name and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      assert html =~ site.name

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/sites")
    end

    test "switches to resources tab, opens add resource panel, and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "switch_panel_tab", %{"tab" => "resources"})
      assert_patch(lv, ~p"/#{account}/sites/#{site.id}?tab=resources")

      html = render_click(lv, "add_resource")
      assert html =~ "Add Resource"
      assert html =~ "Create Resource"

      html = render_click(lv, "close_add_resource")
      assert html =~ "No resources assigned to this site."
    end

    test "manages resource traffic filters and creates a DNS resource for the site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=resources")

      render_click(lv, "add_resource")

      lv
      |> form("[phx-submit='resource_submit']", resource: %{type: "dns"})
      |> render_change()

      render_click(lv, "toggle_resource_filters_dropdown")
      assert has_element?(lv, "button[phx-value-protocol='tcp']", "TCP")

      render_click(lv, "add_resource_filter", %{"protocol" => "tcp"})
      assert has_element?(lv, "input[name='resource[filters][tcp][enabled]'][value='true']")

      render_click(lv, "add_resource_filter", %{"protocol" => "icmp"})
      assert has_element?(lv, "input[name='resource[filters][icmp][enabled]'][value='true']")

      render_click(lv, "remove_resource_filter", %{"protocol" => "icmp"})
      refute has_element?(lv, "input[name='resource[filters][icmp][enabled]'][value='true']")

      html =
        lv
        |> form("[phx-submit='resource_submit']",
          resource: %{
            type: "dns",
            address: "grafana.internal",
            address_description: "Observability",
            name: "Grafana"
          }
        )
        |> render_submit()

      resource =
        Repo.get_by!(Resource,
          account_id: account.id,
          site_id: site.id,
          name: "grafana.internal"
        )

      assert html =~ "Resource grafana.internal created successfully."
      assert html =~ "grafana.internal"
      assert resource.address == "grafana.internal"
    end

    test "shows offline gateways when expanded and filters back to online only", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, name: "edge-sfo-1")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "show_all_gateways")
      assert html =~ gateway.name

      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      assert html =~ "Tunnel IPv4"
      assert html =~ gateway.latest_session.version

      html = render_click(lv, "show_online_gateways")
      assert html =~ "No gateways are currently online."
      refute html =~ gateway.name
    end

    test "opens deploy view, switches tabs, and closes deploy view", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "deploy_gateway")
      assert html =~ "Deploy a Gateway"
      assert html =~ "Choose your deployment environment"

      # Currently defaults to Debian/Ubuntu instructions
      assert html =~ "Add the Firezone APT repository"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "systemd-instructions"})
      assert html =~ "Install via systemd"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "docker-instructions"})
      assert html =~ "docker run"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "terraform-instructions"})
      assert html =~ "Terraform guides"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "custom-instructions"})
      assert html =~ "run the gateway binary directly"

      html = render_click(lv, "close_deploy")
      assert html =~ "Deploy gateway"
      refute html =~ "Deploy a Gateway"
    end

    test "shows account-managed delete confirmation, cancels it, then deletes the site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "confirm_delete_site")
      assert html =~ "Delete this site?"

      html = render_click(lv, "cancel_delete_site")
      refute html =~ "Delete this site?"

      render_click(lv, "confirm_delete_site")
      render_click(lv, "delete_site")

      assert_patch(lv, ~p"/#{account}/sites")
      assert is_nil(Repo.get_by(Site, account_id: account.id, id: site.id))
    end

    test "hides account-only actions for system-managed sites", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = system_site_fixture(%{account: account, name: "Internet"})

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      assert html =~ "system managed"
      refute html =~ "Delete site"
      refute html =~ "Add resource"
    end
  end

  describe "select_site event" do
    test "selects a site from the list and patches to show path", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site_a = site_fixture(account: account)
      site_b = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites")

      render_click(lv, "select_site", %{"id" => site_a.id})
      assert_patch(lv, ~p"/#{account}/sites/#{site_a.id}")

      render_click(lv, "select_site", %{"id" => site_b.id})
      assert_patch(lv, ~p"/#{account}/sites/#{site_b.id}")
    end
  end

  describe ":edit action" do
    test "renders edit form pre-populated with site name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}/edit")

      assert html =~ "Edit Site"
      assert html =~ site.name
      assert html =~ "Save"
    end

    test "opens edit form from the show panel, cancels, and updates the site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "open_site_edit_form")
      assert_patch(lv, ~p"/#{account}/sites/#{site.id}/edit")

      render_click(lv, "cancel_site_edit_form")
      assert_patch(lv, ~p"/#{account}/sites/#{site.id}")

      render_click(lv, "open_site_edit_form")

      html =
        lv
        |> form("[phx-submit='submit_site_edit_form']",
          site: %{name: "Updated Site Name", health_threshold: 5}
        )
        |> render_submit()

      updated_site = Repo.get_by!(Site, account_id: account.id, id: site.id)

      assert html =~ "Site updated successfully."
      assert html =~ "Updated Site Name"
      assert updated_site.name == "Updated Site Name"
      assert updated_site.health_threshold == 5
      assert_patch(lv, ~p"/#{account}/sites/#{site.id}")
    end

    test "updates only the health threshold for system-managed sites", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = system_site_fixture(%{account: account, name: "Managed Site"})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}/edit")

      refute render(lv) =~ "Name <span"

      html =
        lv
        |> form("[phx-submit='submit_site_edit_form']", site: %{health_threshold: 7})
        |> render_submit()

      updated_site = Repo.get_by!(Site, account_id: account.id, id: site.id)

      assert html =~ "Site updated successfully."
      assert updated_site.name == "Managed Site"
      assert updated_site.health_threshold == 7
    end
  end
end
