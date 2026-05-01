defmodule PortalWeb.ResourcesTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Policy, Repo}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.FeaturesFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
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
      assert count_occurrences(html, "No Site Associated") == 3
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
      assert count_occurrences(html, "No Site Needed") == 3
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

    test "cannot select more than 5 groups", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      groups =
        for i <- 1..6 do
          group_fixture(account: account, name: "Select Group #{i}")
        end

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/resources/#{resource.id}")

      render_click(lv, "open_grant_form")

      for group <- Enum.take(groups, 5) do
        render_click(lv, "toggle_grant_group", %{"group_id" => group.id})
      end

      html = render(lv)
      assert html =~ "5 / 5"

      sixth = Enum.at(groups, 5)
      html = render_click(lv, "toggle_grant_group", %{"group_id" => sixth.id})

      assert html =~ "5 / 5"
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
      assert html =~ "1 / 5"

      html = render_click(lv, "toggle_grant_group", %{"group_id" => group.id})
      assert html =~ "0 / 5"
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
            client_remote_ip: {100, 64, 0, 1},
            client_user_agent: "Test/1.0",
            gateway_remote_ip: {100, 64, 0, 2},
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :initiating_device_id,
            :receiving_device_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
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

  defp count_occurrences(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> length()
  end
end
