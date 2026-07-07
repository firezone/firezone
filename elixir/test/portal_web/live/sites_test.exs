defmodule PortalWeb.SitesTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Device, GatewayToken, Repo, Resource, Site}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

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

    test "hides Internet Site on the index for starter accounts without the feature", %{conn: conn} do
      account =
        starter_account_fixture(
          features: %{
            internet_resource: false,
            policy_conditions: true,
            traffic_filters: true,
            idp_sync: true,
            rest_api: true,
            client_to_client: false
          }
        )

      actor = admin_actor_fixture(account: account)
      _internet_resource =
        internet_resource_fixture(account: account, name: "Starter Hidden Internet Resource")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites")

      refute html =~ "Internet Site"
      refute html =~ "Starter Hidden Internet Resource"
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

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          name: "edge-sfo-1",
          last_seen_remote_ip: {198, 51, 100, 20},
          last_seen_remote_ip_location_region: "US",
          last_seen_remote_ip_location_city: "San Francisco",
          last_seen_remote_ip_location_lat: 37.7749,
          last_seen_remote_ip_location_lon: -122.4194
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "show_all_gateways")
      assert html =~ gateway.name

      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      assert html =~ "Remote IP"
      assert html =~ "198.51.100.20"
      assert html =~ "San Francisco"
      assert html =~ "United States of America"
      assert html =~ "google.com/maps/place/37.7749,-122.4194"
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
      assert html =~ "sudo firezone gateway authenticate"
      assert html =~ "Use this token when prompted"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "systemd-instructions"})
      assert html =~ "Install via systemd"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "docker-instructions"})
      assert html =~ "docker run"
      # The portal ignores FIREZONE_NAME for single-owner gateways
      refute html =~ "FIREZONE_NAME"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "terraform-instructions"})
      assert html =~ "Terraform guides"

      html = render_click(lv, "deploy_tab_selected", %{"tab" => "custom-instructions"})
      assert html =~ "Download the latest binary"
      assert html =~ "FIREZONE_TOKEN="
      assert html =~ "sudo sysctl -w net.ipv4.ip_forward=1"
      assert html =~ "sudo iptables -C FORWARD -i tun-firezone"
      assert html =~ "sudo ./firezone-gateway-"

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
      assert html =~ "Delete this Site?"
      assert html =~ "All associated gateways and resources will also be permanently deleted."

      html = render_click(lv, "cancel_delete_site")
      refute html =~ "Delete this Site?"

      render_click(lv, "confirm_delete_site")
      render_click(lv, "delete_site")

      assert_patch(lv, ~p"/#{account}/sites")
      assert is_nil(Repo.get_by(Site, account_id: account.id, id: site.id))
    end

    test "deletes a site with gateway devices without crashing", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "confirm_delete_site")
      html = render_click(lv, "delete_site")

      assert html =~ "Site #{site.name} deleted successfully."
      assert_patch(lv, ~p"/#{account}/sites")
      assert is_nil(Repo.get_by(Site, account_id: account.id, id: site.id))
      assert is_nil(Repo.get_by(Device, account_id: account.id, id: gateway.id))
    end

    test "hides account-only actions for system-managed sites", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = system_site_fixture(%{account: account, name: "Internet"})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      assert has_element?(lv, "span.whitespace-nowrap", "system")
      refute has_element?(lv, "button", "Delete site")
      refute has_element?(lv, "button", "Add resource")
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

    test "patches to sites index with flash when site does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/sites/#{missing_id}")

      assert to == ~p"/#{account}/sites"
      assert flash["error"] =~ "Site does not exist"
    end
  end

  describe "gateways tab" do
    test "deletes a gateway via inline confirmation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      html = render_click(lv, "delete_gateway", %{"id" => gateway.id})
      assert html =~ "Delete this gateway?"

      html = render_click(lv, "confirm_delete_gateway", %{"id" => gateway.id})
      assert html =~ "Gateway deleted."
      refute html =~ gateway.name
      assert is_nil(Repo.get_by(Device, account_id: account.id, id: gateway.id))
    end

    test "cancel delete gateway dismisses the inline confirmation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "delete_gateway", %{"id" => gateway.id})
      assert has_element?(lv, "span", "Delete this gateway?")

      html = render_click(lv, "cancel_delete_gateway")
      refute html =~ "Delete this gateway?"
      assert html =~ gateway.name
      assert Repo.get_by(Device, account_id: account.id, id: gateway.id)
    end
  end

  describe "single-owner tokens" do
    test "deploy pre-creates a gateway with a single-owner token", %{
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

      gateway =
        Repo.get_by!(Device, account_id: account.id, site_id: site.id, type: :gateway)

      assert is_nil(gateway.telemetry_id)

      token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)
      assert is_nil(token.site_id)
      assert is_nil(token.rotated_at)
    end

    test "deploy no longer creates multi-owner site tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "deploy_gateway")

      refute Repo.get_by(GatewayToken, account_id: account.id, site_id: site.id)
    end

    test "rotates a gateway token from the expanded row", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      # The fixture session references the single-owner token, marking it in use
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)
      token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      assert html =~ "Last connected with gateway token"

      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Rotate token"

      html = render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      assert html =~ "Rotate this gateway&#39;s token?"

      html = render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})
      assert html =~ "New gateway token"
      assert html =~ "Copy it now"
      assert html =~ "Copy token"

      assert has_element?(
               lv,
               "[data-copy-to-clipboard-target='gateway-token-reveal-#{gateway.id}-code']"
             )

      assert html =~
               "Last connected with expiring gateway token — Replacement provisioned, but never used"
      assert html =~ "The expiring token keeps working"
      refute html =~ "The legacy site token keeps working"

      old_token = Repo.get_by!(GatewayToken, account_id: account.id, id: token.id)
      assert old_token.rotated_at != nil

      html = render_click(lv, "dismiss_rotated_gateway_token")
      refute html =~ "Copy it now"
    end

    test "reconnect with the replacement shows live status before sessions land", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)
      old_token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})
      render_click(lv, "dismiss_rotated_gateway_token")

      new_token =
        GatewayToken
        |> Repo.all()
        |> Enum.find(&(&1.device_id == gateway.id and is_nil(&1.rotated_at)))

      # The gateway reconnects with the replacement: verification deletes the
      # expiring token (cascading its sessions), presence and the PG registry
      # register immediately, while the new session waits in the async queue
      GatewayToken
      |> Repo.get_by!(account_id: account.id, id: old_token.id)
      |> Repo.delete!()

      :ok = Portal.PG.join(new_token.id)
      :ok = Portal.Presence.Gateways.Account.track(account.id, gateway.id)

      send(lv.pid, %Phoenix.Socket.Broadcast{
        topic: "presences:account_gateways:#{account.id}",
        event: "presence_diff",
        payload: %{joins: %{}, leaves: %{}}
      })

      html = render(lv)
      assert html =~ "Connected with gateway token"
      refute html =~ "Never connected"
      refute html =~ "expiring"
    end

    test "presence diff refreshes per-gateway token state", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      gateway =
        gateway_fixture(account: account, site: site, name: "doomed-gw", token: :single_owner)

      token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      # Offline, but listed by default because it has a gateway token
      assert html =~ "doomed-gw"

      GatewayToken
      |> Repo.get_by!(account_id: account.id, id: token.id)
      |> Repo.delete!()

      send(lv.pid, %Phoenix.Socket.Broadcast{
        topic: "presences:account_gateways:#{account.id}",
        event: "presence_diff",
        payload: %{joins: %{}, leaves: %{}}
      })

      html = render(lv)
      refute html =~ "doomed-gw"
    end

    test "cancelling a rotation keeps the token untouched", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)
      token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})

      html = render_click(lv, "cancel_rotate_gateway_token")
      refute html =~ "Rotate this gateway&#39;s token?"

      token = Repo.get_by!(GatewayToken, account_id: account.id, id: token.id)
      assert is_nil(token.rotated_at)
    end

    test "shows token status for a legacy gateway without a single-owner token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      assert html =~ "Last connected with legacy site token"
      refute html =~ "Gateway token provisioned"

      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Upgrade token"
      refute html =~ "Rotate token"
      refute html =~ "Generate token"
    end

    test "badges gateways connected with a legacy token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      legacy_gateway = gateway_fixture(account: account, site: site, name: "legacy-gw")

      single_owner_gateway =
        gateway_fixture(account: account, site: site, name: "pet-gw", token: :single_owner)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "show_all_gateways")

      assert html =~ legacy_gateway.name
      assert html =~ single_owner_gateway.name
      assert html =~ "legacy token"

      # Only the legacy-connected gateway carries the badge
      assert badge_count(html) == 1
    end

    test "single-owner gateways are listed even when offline", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      legacy_gateway = gateway_fixture(account: account, site: site, name: "legacy-gw")

      single_owner_gateway =
        gateway_fixture(account: account, site: site, name: "pet-gw", token: :single_owner)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      # Default view (online only): the offline single-owner gateway is still
      # visible because its token maps to exactly one gateway
      assert html =~ single_owner_gateway.name
      refute html =~ legacy_gateway.name
    end

    test "single-owner connected gateway shows status without legacy note", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})

      assert html =~ "Last connected with gateway token"
      refute html =~ "legacy site token"
      refute html =~ "legacy token</span>"
    end

    test "upgrade confirmation explains legacy tokens stay valid", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})

      html = render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})

      assert html =~ "Upgrade this gateway to its own token?"
      assert html =~ "keeps working until you revoke"
      assert html =~ "the Legacy tokens tab"
      refute html =~ "4 hours pass"
      refute html =~ "gateway token from the earlier upgrade"
    end

    test "re-upgrading a legacy gateway replaces the unused token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      html = render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})

      first_token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)
      assert html =~ "Copy it now"

      # Mid-upgrade status: legacy session with an unused gateway token
      assert html =~ "Last connected with legacy site token — Gateway token provisioned, but never used"

      # While the new token is revealed, the menu hides the token action
      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Rename gateway"
      refute html =~ "Upgrade token"
      refute html =~ "Rotate token"
      render_click(lv, "close_gateway_actions")

      # Still mid-upgrade after dismissing: the gateway is on its legacy
      # token, so the menu keeps offering an upgrade rather than a rotation
      render_click(lv, "dismiss_rotated_gateway_token")
      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Upgrade token"
      refute html =~ "Rotate token"

      html = render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      assert html =~ "unused gateway token from the earlier upgrade"

      render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})

      # The never-used first token is replaced outright, not put in grace
      refute Repo.get_by(GatewayToken, account_id: account.id, id: first_token.id)

      second_token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)
      assert is_nil(second_token.rotated_at)
    end

    test "shows plain generate action for a gateway with no token or session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      gateway =
        Repo.insert!(%Device{
          account_id: account.id,
          site_id: site.id,
          type: :gateway,
          name: "bare-gw"
        })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      assert html =~ "Never connected — No token provisioned"

      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Generate token"
      refute html =~ "Upgrade token"
      refute html =~ "Rotate token"

      html = render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})

      assert html =~ "Generate a gateway token?"
      refute html =~ "the Legacy tokens tab"
    end

    test "upgrade reveal says the legacy token stays valid until revoked", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      html = render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})

      assert html =~ "Copy it now"
      assert html =~ "The legacy site token keeps working"
      refute html =~ "The expiring token keeps working"
      refute html =~ "4 hours pass"
    end

    test "generate reveal has no old-token caveats", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      gateway =
        Repo.insert!(%Device{
          account_id: account.id,
          site_id: site.id,
          type: :gateway,
          name: "bare-gw"
        })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      html = render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})

      assert html =~ "Copy it now"
      refute html =~ "The expiring token keeps working"
      refute html =~ "The legacy site token keeps working"
    end

    test "rotating a never-used token is presented as replacement", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      # A deploy-created gateway: token minted, but never connected
      gateway =
        Repo.insert!(%Device{
          account_id: account.id,
          site_id: site.id,
          type: :gateway,
          name: "deployed-gw"
        })

      token = gateway_token_fixture(gateway: gateway)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      html = render_click(lv, "toggle_gateway_expand", %{"id" => gateway.id})
      assert html =~ "Never connected — Gateway token provisioned"

      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Rotate token"

      html = render_click(lv, "rotate_gateway_token", %{"id" => gateway.id})
      assert html =~ "so it will be replaced immediately"
      refute html =~ "4 hours pass"

      html = render_click(lv, "confirm_rotate_gateway_token", %{"id" => gateway.id})
      assert html =~ "never used and has been replaced"
      refute html =~ "The expiring token keeps working"
      assert html =~ "Never connected — Gateway token provisioned"

      refute Repo.get_by(GatewayToken, account_id: account.id, id: token.id)
    end
  end

  describe "gateway actions menu" do
    test "lists rename, token action, and delete", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      refute html =~ "Rename gateway"

      html = render_click(lv, "toggle_gateway_actions", %{"id" => gateway.id})
      assert html =~ "Rename gateway"
      assert html =~ "Rotate token"
      assert html =~ "Delete gateway"

      html = render_click(lv, "close_gateway_actions")
      refute html =~ "Rename gateway"
    end
  end

  describe "gateway rename" do
    test "renames a gateway via the inline form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")

      render_click(lv, "rename_gateway", %{"id" => gateway.id})
      assert has_element?(lv, "#rename-gateway-#{gateway.id}")

      html = render_submit(lv, "save_gateway_name", %{"name" => "edge-nyc-1"})
      assert html =~ "Gateway renamed."
      assert html =~ "edge-nyc-1"
      refute has_element?(lv, "#rename-gateway-#{gateway.id}")

      assert Repo.get_by!(Device, account_id: account.id, id: gateway.id).name == "edge-nyc-1"
    end

    test "rejects a blank name", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "rename_gateway", %{"id" => gateway.id})

      html = render_submit(lv, "save_gateway_name", %{"name" => "   "})
      assert html =~ "Failed to rename gateway."

      assert Repo.get_by!(Device, account_id: account.id, id: gateway.id).name == gateway.name
    end

    test "cancelling the rename keeps the name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      render_click(lv, "show_all_gateways")
      render_click(lv, "rename_gateway", %{"id" => gateway.id})
      assert has_element?(lv, "#rename-gateway-#{gateway.id}")

      html = render_click(lv, "cancel_rename_gateway")
      refute has_element?(lv, "#rename-gateway-#{gateway.id}")
      assert html =~ gateway.name

      assert Repo.get_by!(Device, account_id: account.id, id: gateway.id).name == gateway.name
    end
  end

  describe "legacy token usage" do
    test "shows unused badge for a token with no live connections", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      _token = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      html = render(lv)
      assert html =~ "unused"
      refute html =~ "connected</span>"
    end

    test "shows live connection count for a token in use", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      # Simulate a gateway channel connected with this token
      :ok = Portal.PG.join(token.id)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      html = render(lv)
      assert html =~ "1 connected"
      refute html =~ "unused"
    end
  end

  describe "tokens tab" do
    test "renders existing tokens on the tokens tab", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token1 = gateway_token_fixture(account: account, site: site)
      token2 = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      html = render(lv)
      assert html =~ token1.id
      assert html =~ token2.id
      assert html =~ "Legacy tokens"
    end

    test "hides the Legacy tokens tab when the site has no legacy tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      _gateway = gateway_fixture(account: account, site: site, token: :single_owner)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}")

      refute html =~ "Legacy tokens"
      assert html =~ "Gateways"
    end

    test "?tab=tokens falls back to gateways when the site has no legacy tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      assert html =~ "Deploy gateway"
      refute html =~ "Legacy tokens"
    end

    test "revoking the last legacy token switches back to the gateways tab", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      render_click(lv, "revoke_gateway_token", %{"id" => token.id})
      html = render_click(lv, "confirm_revoke_gateway_token", %{"id" => token.id})

      assert html =~ "Token revoked."
      assert html =~ "Deploy gateway"
      refute html =~ "Legacy tokens"
    end

    test "revokes a single gateway token via inline confirmation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      html = render_click(lv, "revoke_gateway_token", %{"id" => token.id})
      assert html =~ "Revoke this token?"

      html = render_click(lv, "confirm_revoke_gateway_token", %{"id" => token.id})
      assert html =~ "Token revoked."
      refute html =~ token.id
      refute Repo.get_by(GatewayToken, account_id: account.id, id: token.id)
    end

    test "cancel revoke single token dismisses the inline confirmation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      render_click(lv, "revoke_gateway_token", %{"id" => token.id})
      assert has_element?(lv, "span", "Revoke this token?")

      html = render_click(lv, "cancel_revoke_gateway_token")
      refute html =~ "Revoke this token?"
      assert html =~ token.id
      assert Repo.get_by(GatewayToken, account_id: account.id, id: token.id)
    end

    test "revoke all tokens shows confirmation then deletes all", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token1 = gateway_token_fixture(account: account, site: site)
      token2 = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      html = render_click(lv, "confirm_revoke_all_tokens")
      assert html =~ "Revoke all tokens?"

      html = render_click(lv, "revoke_all_gateway_tokens")
      assert html =~ "All tokens revoked."
      refute html =~ token1.id
      refute html =~ token2.id
      refute Repo.get_by(GatewayToken, account_id: account.id, id: token1.id)
      refute Repo.get_by(GatewayToken, account_id: account.id, id: token2.id)

      # Tab flips back to gateways now that the Legacy tokens tab is gone
      assert html =~ "Deploy gateway"
      refute html =~ "Legacy tokens"
    end

    test "cancel revoke all tokens dismisses the confirmation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/sites/#{site.id}?tab=tokens")

      render_click(lv, "confirm_revoke_all_tokens")
      assert has_element?(lv, "span", "Revoke all tokens?")

      html = render_click(lv, "cancel_revoke_all_tokens")
      refute html =~ "Revoke all tokens?"
      assert html =~ token.id
      assert Repo.get_by(GatewayToken, account_id: account.id, id: token.id)
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

  defp badge_count(html) do
    html |> String.split("legacy token") |> length() |> Kernel.-(1)
  end
end
