defmodule PortalWeb.ResourcesTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Policy, Repo}
  alias Portal.Changes.Change
  alias Portal.Resource

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientSessionFixtures
  import Portal.DeviceFixtures
  import Portal.FeaturesFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/resources"

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
    test "renders resource list page", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert html =~ "Resources"
      assert html =~ resource.name
    end

    test "opens new resource panel from list and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert html =~ "New Resource"

      render_click(lv, "open_new_form")
      assert_patch(lv, ~p"/#{account}/resources/new")
      assert render(lv) =~ "Add Resource"

      render_click(lv, "cancel_resource_form")
      assert_patch(lv, ~p"/#{account}/resources")
      refute render(lv) =~ "Add Resource"
    end

    test "shows conventional nil-site copy in the resources table", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert html =~ resource.name
      assert count_occurrences(html, "No Site Associated") == 1
      refute html =~ "No Site Needed"
    end

    test "shows device pool nil-site copy in the resources table", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = static_device_pool_resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert html =~ resource.name
      assert count_occurrences(html, "No Site Needed") == 1
      refute html =~ "No Site Associated"
    end

    test "shows online member count instead of offline for device pools", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client_one = client_fixture(account: account, actor: actor)
      client_two = client_fixture(account: account, actor: actor)

      _resource =
        static_device_pool_resource_fixture(account: account, clients: [client_one, client_two])

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert html =~ "0 / 2 online"
    end

    test "hides device pool option from the type filter when client_to_client is disabled",
         %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      refute has_element?(lv, "#resources-type-static_device_pool")
      assert has_element?(lv, "#resources-type-dns")
    end

    test "shows device pool option in the type filter when client_to_client is enabled",
         %{conn: conn, account: account, actor: actor} do
      enable_feature(:client_to_client)
      account = update_account(account, features: %{client_to_client: true})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert has_element?(lv, "#resources-type-static_device_pool")
      assert has_element?(lv, "#resources-type-dns")
    end

    test "hides Internet Resource row for starter accounts without the feature", %{conn: conn} do
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
        |> live(~p"/#{account}/resources")

      refute html =~ "Starter Hidden Internet Resource"
      refute html =~ "Network traffic outside defined resources"
    end
  end

  describe ":new action" do
    test "renders add resource form", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      assert html =~ "Add Resource"
      assert html =~ "Create Resource"
    end

    test "creates a DNS resource on submit", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      # Select type first to enable the address field
      lv
      |> form("[phx-submit='submit_resource_form']", resource: %{type: "dns"})
      |> render_change()

      html =
        lv
        |> form("[phx-submit='submit_resource_form']",
          resource: %{
            type: "dns",
            name: "App Example",
            address: "app.example.com",
            site_id: site.id
          }
        )
        |> render_submit()

      assert html =~ "created successfully"
    end

    test "creates an IP resource on submit", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      lv
      |> form("[phx-submit='submit_resource_form']", resource: %{type: "ip"})
      |> render_change()

      html =
        lv
        |> form("[phx-submit='submit_resource_form']",
          resource: %{type: "ip", name: "My IP Resource", address: "10.0.0.1", site_id: site.id}
        )
        |> render_submit()

      assert html =~ "created successfully"
    end

    test "creates a CIDR resource on submit", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      # Select type first to enable the address field
      lv
      |> form("[phx-submit='submit_resource_form']", resource: %{type: "cidr"})
      |> render_change()

      html =
        lv
        |> form("[phx-submit='submit_resource_form']",
          resource: %{
            type: "cidr",
            name: "My CIDR Resource",
            address: "10.0.5.0/24",
            site_id: site.id
          }
        )
        |> render_submit()

      assert html =~ "created successfully"
    end

    test "creates a Device Pool resource on submit", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_feature(:client_to_client)
      account = update_account(account, features: %{client_to_client: true})

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      lv
      |> form("[phx-submit='submit_resource_form']",
        resource: %{type: "static_device_pool", name: "My Device Pool"}
      )
      |> render_change()

      html =
        lv
        |> form("[phx-submit='submit_resource_form']",
          resource: %{type: "static_device_pool", name: "My Device Pool"}
        )
        |> render_submit()

      assert html =~ "created successfully"
    end

    test "manages DNS traffic restriction controls", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      lv
      |> form("[phx-submit='submit_resource_form']", resource: %{type: "dns"})
      |> render_change()

      render_click(lv, "toggle_resource_filters_dropdown")
      assert has_element?(lv, "button[phx-value-protocol='tcp']", "TCP")

      render_click(lv, "add_resource_filter", %{"protocol" => "tcp"})
      assert has_element?(lv, "input[name='resource[filters][tcp][enabled]'][value='true']")

      render_click(lv, "add_resource_filter", %{"protocol" => "icmp"})
      assert has_element?(lv, "input[name='resource[filters][icmp][enabled]'][value='true']")

      render_click(lv, "remove_resource_filter", %{"protocol" => "icmp"})
      refute has_element?(lv, "input[name='resource[filters][icmp][enabled]'][value='true']")

      render_click(lv, "add_resource_filter", %{"protocol" => "icmp"})
      assert has_element?(lv, "input[name='resource[filters][icmp][enabled]'][value='true']")
      assert has_element?(lv, "input[name='resource[filters][tcp][ports]']")
    end

    test "manages static device pool traffic restriction controls and creates resource with filters",
         %{
           conn: conn,
           account: account,
           actor: actor
         } do
      enable_feature(:client_to_client)

      features =
        account.features
        |> Map.from_struct()
        |> Map.put(:client_to_client, true)

      account = update_account(account, features: features)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      lv
      |> form("[phx-submit='submit_resource_form']", resource: %{type: "static_device_pool"})
      |> render_change()

      render_click(lv, "toggle_resource_filters_dropdown")
      assert has_element?(lv, "button[phx-value-protocol='tcp']", "TCP")

      render_click(lv, "add_resource_filter", %{"protocol" => "tcp"})
      assert has_element?(lv, "input[name='resource[filters][tcp][enabled]'][value='true']")
      assert has_element?(lv, "input[name='resource[filters][tcp][ports]']")

      render_click(lv, "add_resource_filter", %{"protocol" => "icmp"})
      assert has_element?(lv, "input[name='resource[filters][icmp][enabled]'][value='true']")

      html =
        lv
        |> form("[phx-submit='submit_resource_form']",
          resource: %{
            type: "static_device_pool",
            name: "Filtered Device Pool",
            filters: %{
              tcp: %{enabled: "true", protocol: "tcp", ports: "443, 8443"},
              icmp: %{enabled: "true", protocol: "icmp"}
            }
          }
        )
        |> render_submit()

      assert html =~ "created successfully"

      resource =
        Repo.get_by!(Portal.Resource, account_id: account.id, name: "Filtered Device Pool")

      assert Map.new(resource.filters, &{&1.protocol, &1.ports}) == %{
               tcp: ["443", "8443"],
               icmp: []
             }
    end

    test "manages static device pool client picker", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_feature(:client_to_client)
      account = update_account(account, features: %{client_to_client: true})
      client = client_fixture(account: account, actor: actor, name: "Workstation Alpha")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/new")

      lv
      |> form("[phx-submit='submit_resource_form']", resource: %{type: "static_device_pool"})
      |> render_change()

      assert render_focus(element(lv, "input[name='client_search']")) =~ "Search clients to add"

      html =
        lv
        |> element("input[name='client_search']")
        |> render_change(%{"client_search" => "Workstation"})

      assert html =~ client.name

      html = render_click(lv, "add_client", %{"client_id" => client.id})
      assert html =~ client.name

      html = render_click(lv, "remove_client", %{"client_id" => client.id})
      assert html =~ "Search above to add devices"

      lv
      |> element("input[name='client_search']")
      |> render_change(%{"client_search" => "Workstation"})

      html = render_click(lv, "add_client", %{"client_id" => client.id})
      assert html =~ client.name

      assert has_element?(
               lv,
               "button[phx-click='remove_client'][phx-value-client_id='#{client.id}']"
             )
    end

    test "client picker search surfaces online clients ahead of the result limit", %{
      account: account,
      actor: actor
    } do
      subject = admin_subject_fixture(account: account, actor: actor)

      for i <- 1..10 do
        client_fixture(account: account, actor: actor, name: "Bulk Offline #{i}")
      end

      online_client = client_fixture(account: account, actor: actor, name: "Bulk Online")
      :ok = Portal.Presence.Clients.Account.track(account.id, online_client.id)

      results = PortalWeb.Resources.Components.Database.search_clients("Bulk", subject, [])

      assert length(results) == 10
      assert [%{id: id, online?: true} | _] = results
      assert id == online_client.id
    end
  end

  describe ":show action" do
    test "renders resource detail panel", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ resource.name
      assert html =~ resource.address
    end

    test "shows conventional nil-site copy consistently in the selected resource panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ resource.name
      assert count_occurrences(html, "No Site Associated") == 2
      refute html =~ "No Site Needed"
    end

    test "shows device pool nil-site copy consistently in the selected resource panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = static_device_pool_resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ resource.name
      assert count_occurrences(html, "No Site Needed") == 2
      refute html =~ "No Site Associated"
    end

    test "opens grant access form, creates access, and returns to list", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Engineering")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "open_grant_form")
      assert html =~ "Grant access"
      assert html =~ group.name

      html = render_click(lv, "toggle_grant_group", %{"group_id" => group.id})
      assert html =~ group.name

      html =
        lv
        |> form("#grant-form")
        |> render_submit()

      assert html =~ "Grant access"
      assert html =~ group.name
      assert html =~ ">1<"
      assert Repo.get_by!(Policy, resource_id: resource.id, group_id: group.id)

      html = render_click(lv, "open_grant_form")
      assert html =~ "Grant access"

      html = render_click(lv, "close_grant_form")
      assert html =~ "Grant access"
    end

    test "shows blurred upgrade state in grant access form for starter accounts without policy conditions",
         %{conn: conn} do
      account =
        starter_account_fixture(
          features: %{
            policy_conditions: false,
            traffic_filters: true,
            idp_sync: true,
            rest_api: true,
            client_to_client: false
          }
        )

      actor = admin_actor_fixture(account: account)
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "open_grant_form")

      assert html =~ "Upgrade your plan to unlock policy conditions."
      assert html =~ "Upgrade to Unlock"
      assert html =~ ~s(href="/#{account.slug}/settings/account")
      assert html =~ ~s(id="resource-grant-conditions-locked-container")
      assert html =~ "blur-[2px]"
      assert html =~ "ri-lock-2-line"
      refute html =~ "Add condition"
      refute html =~ ~s(phx-click="remove_condition")
    end

    test "grants access to multiple groups at once", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group1 = group_fixture(account: account, name: "Team Alpha")
      group2 = group_fixture(account: account, name: "Team Beta")
      group3 = group_fixture(account: account, name: "Team Gamma")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      render_click(lv, "open_grant_form")
      render_click(lv, "toggle_grant_group", %{"group_id" => group1.id})
      render_click(lv, "toggle_grant_group", %{"group_id" => group2.id})
      render_click(lv, "toggle_grant_group", %{"group_id" => group3.id})

      lv |> form("#grant-form") |> render_submit()

      assert Repo.get_by!(Policy, resource_id: resource.id, group_id: group1.id)
      assert Repo.get_by!(Policy, resource_id: resource.id, group_id: group2.id)
      assert Repo.get_by!(Policy, resource_id: resource.id, group_id: group3.id)
    end

    test "toggling a selected group deselects it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Toggled Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      render_click(lv, "open_grant_form")

      html = render_click(lv, "toggle_grant_group", %{"group_id" => group.id})
      refute html =~ "No groups selected."

      html = render_click(lv, "toggle_grant_group", %{"group_id" => group.id})
      assert html =~ "No groups selected."
    end

    test "already-granted groups are not shown in available list", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Already Granted Group")
      _policy = policy_fixture(account: account, resource: resource, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "open_grant_form")

      refute html =~ "Already Granted Group"
    end

    test "disables, enables, and removes group access", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Ops Team")
      _policy = policy_fixture(account: account, resource: resource, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert render_click(lv, "toggle_group_actions", %{"group_id" => group.id}) =~ "Disable"

      render_click(lv, "disable_policy", %{"group_id" => group.id})

      policy = Repo.get_by!(Policy, resource_id: resource.id, group_id: group.id)
      assert policy.disabled_at

      assert render_click(lv, "toggle_group_actions", %{"group_id" => group.id}) =~ "Enable"

      render_click(lv, "enable_policy", %{"group_id" => group.id})

      policy = Repo.get_by!(Policy, resource_id: resource.id, group_id: group.id)
      assert is_nil(policy.disabled_at)

      assert render_click(lv, "toggle_group_actions", %{"group_id" => group.id}) =~
               "Remove access"

      html = render_click(lv, "confirm_remove_group", %{"group_id" => group.id})
      assert html =~ "All group members will immediately lose access."

      html = render_click(lv, "remove_group_access", %{"group_id" => group.id})
      assert html =~ "No groups have access yet."
      assert is_nil(Repo.get_by(Policy, resource_id: resource.id, group_id: group.id))
    end

    test "shows flash and refreshes group list when remove_group_access loses race", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Ops Team")
      policy = policy_fixture(account: account, resource: resource, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      Repo.delete!(policy)

      render_click(lv, "confirm_remove_group", %{"group_id" => group.id})
      html = render_click(lv, "remove_group_access", %{"group_id" => group.id})

      assert html =~ "Group access no longer exists."
      assert html =~ "No groups have access yet."
    end

    test "shows flash when disable_policy loses race", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Ops Team")
      policy = policy_fixture(account: account, resource: resource, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      Repo.delete!(policy)

      html = render_click(lv, "disable_policy", %{"group_id" => group.id})

      assert html =~ "Group access state has changed."
    end

    test "shows flash when enable_policy loses race", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account, name: "Ops Team")

      policy =
        policy_fixture(
          account: account,
          resource: resource,
          group: group,
          disabled_at: DateTime.utc_now()
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      Repo.delete!(policy)

      html = render_click(lv, "enable_policy", %{"group_id" => group.id})

      assert html =~ "Group access state has changed."
    end

    test "internet resource ignores edit and delete actions", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = internet_resource_fixture(account: account)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ resource.name
      refute html =~ "Delete resource"
      refute html =~ " Edit"

      html = render_click(lv, "open_edit_form")
      refute html =~ "Edit Resource"

      html = render_click(lv, "confirm_delete_resource")
      refute html =~ "Delete this resource?"
    end

    test "close button dismisses resource detail panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/resources")
    end

    test "patches to resources index with flash when resource does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/resources/#{missing_id}")

      assert to == ~p"/#{account}/resources"
      assert flash["error"] =~ "Resource does not exist"
    end
  end

  describe ":edit action" do
    test "renders edit resource form pre-populated", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}/edit")

      assert html =~ "Edit Resource"
      assert html =~ "Save Changes"
      assert html =~ resource.name
    end

    test "updates resource name on submit", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}/edit")

      html =
        lv
        |> form("[phx-submit='submit_resource_form']",
          resource: %{name: "Updated Resource Name"}
        )
        |> render_submit()

      assert html =~ "updated successfully"
      assert html =~ "Updated Resource Name"
    end

    test "shows confirm delete then deletes resource", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "confirm_delete_resource")
      assert html =~ "Delete"

      render_click(lv, "delete_resource")
      assert_patch(lv, ~p"/#{account}/resources")
    end

    test "cancel button returns to resource details", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}/edit")

      render_click(lv, "cancel_resource_form")
      assert_patch(lv, ~p"/#{account}/resources/#{resource.id}")
    end

    test "cancel delete resource dismisses confirmation", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "confirm_delete_resource")
      assert html =~ "Delete this resource?"

      html = render_click(lv, "cancel_delete_resource")
      refute html =~ "Delete this resource?"
    end

    test "defaults to Groups tab and shows tab bar", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ "Groups"
      assert html =~ "Authorizations"
    end

    test "switching to Authorizations tab patches URL", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      render_click(lv, "switch_resource_tab", %{"tab" => "authorizations"})
      assert_patch(lv, ~p"/#{account}/resources/#{resource.id}?tab=authorizations")
    end

    test "switching back to Groups tab patches URL", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}?tab=authorizations")

      render_click(lv, "switch_resource_tab", %{"tab" => "groups"})
      assert_patch(lv, ~p"/#{account}/resources/#{resource.id}?tab=groups")
    end

    test "Authorizations tab shows empty state when no authorizations exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}?tab=authorizations")

      assert html =~ "No recent policy authorizations"
    end

    test "Authorizations tab renders actor name for membership-based authorization", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      named_actor = actor_fixture(account: account, name: "Alice Smith")
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)
      membership = membership_fixture(account: account, actor: named_actor, group: group)
      policy = policy_fixture(account: account, group: group, resource: resource)

      policy_authorization_fixture(
        account: account,
        actor: named_actor,
        resource: resource,
        group: group,
        policy: policy,
        membership: membership
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}?tab=authorizations")

      assert html =~ "Alice Smith"
    end

    test "Authorizations tab renders actor name from token for nil membership authorization", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      client = client_fixture(account: account, actor: actor)
      gateway = gateway_fixture(account: account, site: site)
      token = client_token_fixture(account: account, actor: actor)

      {:ok, _pa} =
        %Portal.PolicyAuthorization{}
        |> Ecto.Changeset.cast(
          %{
            policy_id: policy.id,
            initiating_device_id: client.id,
            receiving_device_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: nil,
            initiator_remote_ip: {100, 64, 0, 1},
            initiator_user_agent: "Test/1.0",
            receiver_remote_ip: {100, 64, 0, 2},
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :initiating_device_id,
            :receiving_device_id,
            :resource_id,
            :token_id,
            :membership_id,
            :initiator_remote_ip,
            :initiator_user_agent,
            :receiver_remote_ip,
            :expires_at
          ]
        )
        |> Ecto.Changeset.put_assoc(:account, account)
        |> Portal.PolicyAuthorization.changeset()
        |> Repo.insert()

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}?tab=authorizations")

      assert html =~ actor.name
    end

    test "Groups tab still renders correctly as default (regression)", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)
      policy_fixture(account: account, group: group, resource: resource)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ "Grant access"
      assert html =~ group.name
    end

    test "grant form opens from within Groups tab", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "open_grant_form")
      assert html =~ "Grant access"
    end
  end

  describe "count badge" do
    test "shows total resource count after async load", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _resource = resource_fixture(account: account)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      assert html =~ "Loading..."

      html = render_async(lv)

      assert html =~ "1"
      assert html =~ "Total"
      refute html =~ "Loading..."
    end

    test "increments count on resource insert change", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      render_async(lv)

      send(lv.pid, %Change{op: :insert, struct: %Resource{type: :dns}})

      html = render(lv)
      assert html =~ "1"
      assert html =~ "Total"
    end

    test "decrements count on resource delete change", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      render_async(lv)

      send(lv.pid, %Change{op: :delete, old_struct: %Resource{type: :dns}})

      html = render(lv)
      assert html =~ "0"
      assert html =~ "Total"
    end

    test "ignores internet resource changes", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources")

      render_async(lv)

      send(lv.pid, %Change{op: :insert, struct: %Resource{type: :internet}})

      html = render(lv)
      assert html =~ "0"
      assert html =~ "Total"
    end
  end

  describe ":show clients tab (device pool)" do
    test "defaults to the clients tab for device pool resources", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert has_element?(lv, "button[role='tab'][aria-selected]", "Pool Members")
    end

    test "lists pool clients with owner and tunnel IPs", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ client.name
      assert html =~ client.actor.name
      assert html =~ to_string(client.ipv4)
    end

    test "shows an offline status for clients without presence", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ "Offline"
      assert html =~ "0 / 1 online"
    end

    test "shows an online status for connected clients", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      :ok = Portal.Presence.Clients.Account.track(account.id, client.id)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ "Online"
      assert html =~ "1 / 1 online"
    end

    test "shows an empty state when the pool has no clients", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = static_device_pool_resource_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      assert html =~ "No clients in this pool"
    end

    test "expands and collapses a client row to reveal details", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client =
        client_fixture(account: account, actor: actor, device_serial: "SERIAL-1234")

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      refute html =~ "Tunnel IPv6"

      html = render_click(lv, "toggle_pool_client_row", %{"id" => client.id})
      assert html =~ "Tunnel IPv6"
      assert html =~ to_string(client.ipv6)
      assert html =~ "SERIAL-1234"
      assert has_element?(lv, ~s|a[href="/#{account.slug}/clients/#{client.id}"]|)

      html = render_click(lv, "toggle_pool_client_row", %{"id" => client.id})
      refute html =~ "Tunnel IPv6"
    end

    test "shows operating system and last seen from the latest session when expanded", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      _session =
        client_session_fixture(
          account: account,
          actor: actor,
          client: client,
          user_agent: "Mac OS/14.0 connlib/1.3.0"
        )

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      html = render_click(lv, "toggle_pool_client_row", %{"id" => client.id})

      assert html =~ "Operating System"
      assert html =~ "Mac OS 14.0"
      assert html =~ "Last Seen"
    end

    test "switching to the clients tab patches the URL", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = client_fixture(account: account, actor: actor)

      resource =
        static_device_pool_resource_fixture(account: account, clients: [client])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}?tab=groups")

      render_click(lv, "switch_resource_tab", %{"tab" => "clients"})
      assert_patch(lv, ~p"/#{account}/resources/#{resource.id}?tab=clients")

      assert has_element?(lv, "button[role='tab'][aria-selected]", "Pool Members")
    end

    test "does not show the clients tab for non-device-pool resources", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      refute has_element?(lv, "button[role='tab']", "Pool Members")
      assert has_element?(lv, "button[role='tab'][aria-selected]", "Groups")
    end

    test "ignores the clients tab for non-device-pool resources and falls back to groups", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}?tab=clients")

      assert has_element?(lv, "button[role='tab'][aria-selected]", "Groups")
    end
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> length()
  end
end
