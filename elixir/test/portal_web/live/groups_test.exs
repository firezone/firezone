defmodule PortalWeb.GroupsTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Group, Membership, Policy, Repo}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/groups"

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
    test "renders groups page", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups")

      assert html =~ "Groups"
    end

    test "renders existing groups in the list", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups")

      assert html =~ group.name
    end
  end

  describe ":new action" do
    test "renders create group form", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/new")

      assert html =~ "Group Name"
    end

    test "shows validation error for empty group name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/new")

      html =
        lv
        |> form("#group-form", group: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "creates group and navigates away on valid submit", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/new")

      lv
      |> form("#group-form", group: %{name: "Test Group"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Test Group"
    end

    test "adds members before create and closes panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account, name: "Member Search Actor")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/new")

      assert render_focus(element(lv, "input[name='group[member_search]']")) =~
               "Search to add members"

      html =
        lv
        |> form("#group-form", group: %{name: "Ops Team", member_search: "Member Search"})
        |> render_change()

      assert html =~ other_actor.name

      html = render_click(lv, "add_member", %{"actor_id" => other_actor.id})
      assert html =~ "To Add"
      assert html =~ other_actor.name

      html = render_click(lv, "remove_member", %{"actor_id" => other_actor.id})
      refute html =~ "Member Search Actor"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/groups")
    end
  end

  describe ":show action" do
    test "renders group detail panel with group name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}")

      assert html =~ group.name
    end

    test "shows group member list", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      other_actor = actor_fixture(account: account)
      _membership = membership_fixture(actor: other_actor, group: group)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}")

      assert html =~ other_actor.name
    end

    test "switches to resources tab and grants access", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account, name: "Private API")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}")

      render_click(lv, "switch_group_tab", %{"tab" => "resources"})
      assert_patch(lv, ~p"/#{account}/groups/#{group.id}?tab=resources")

      html = render_click(lv, "open_grant_resource_form")
      assert html =~ "Grant access"
      assert html =~ resource.name

      html = render_click(lv, "toggle_grant_resource", %{"resource_id" => resource.id})
      assert html =~ resource.name

      html =
        lv
        |> form("#grant-resource-form")
        |> render_submit()

      assert html =~ resource.name

      policy = Repo.get_by!(Policy, group_id: group.id, resource_id: resource.id)
      assert policy

      html = render_click(lv, "open_grant_resource_form")
      assert html =~ "Grant access"
      assert render_click(lv, "close_grant_resource_form") =~ resource.name
    end

    test "grants access to multiple resources at once", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource1 = resource_fixture(account: account, name: "Resource Alpha")
      resource2 = resource_fixture(account: account, name: "Resource Beta")
      resource3 = resource_fixture(account: account, name: "Resource Gamma")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}?tab=resources")

      render_click(lv, "open_grant_resource_form")
      render_click(lv, "toggle_grant_resource", %{"resource_id" => resource1.id})
      render_click(lv, "toggle_grant_resource", %{"resource_id" => resource2.id})
      render_click(lv, "toggle_grant_resource", %{"resource_id" => resource3.id})

      lv |> form("#grant-resource-form") |> render_submit()

      assert Repo.get_by!(Policy, group_id: group.id, resource_id: resource1.id)
      assert Repo.get_by!(Policy, group_id: group.id, resource_id: resource2.id)
      assert Repo.get_by!(Policy, group_id: group.id, resource_id: resource3.id)
    end

    test "cannot select more than 5 resources", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)

      resources =
        for i <- 1..6 do
          resource_fixture(account: account, name: "Select Resource #{i}")
        end

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}?tab=resources")

      render_click(lv, "open_grant_resource_form")

      for resource <- Enum.take(resources, 5) do
        render_click(lv, "toggle_grant_resource", %{"resource_id" => resource.id})
      end

      html = render(lv)
      assert html =~ "5 / 5"

      sixth = Enum.at(resources, 5)
      html = render_click(lv, "toggle_grant_resource", %{"resource_id" => sixth.id})

      assert html =~ "5 / 5"
    end

    test "toggling a selected resource deselects it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account, name: "Toggled Resource")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}?tab=resources")

      render_click(lv, "open_grant_resource_form")

      html = render_click(lv, "toggle_grant_resource", %{"resource_id" => resource.id})
      assert html =~ "1 / 5"

      html = render_click(lv, "toggle_grant_resource", %{"resource_id" => resource.id})
      assert html =~ "0 / 5"
    end

    test "already-granted resources are not shown in available list", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account, name: "Already Granted Resource")
      _policy = policy_fixture(account: account, group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}?tab=resources")

      html = render_click(lv, "open_grant_resource_form")

      refute html =~ "Already Granted Resource"
    end

    test "disables, enables, and removes resource access", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account, name: "Internal DB")
      _policy = policy_fixture(account: account, group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}?tab=resources")

      assert render_click(lv, "toggle_resource_access_actions", %{"resource_id" => resource.id}) =~
               "Disable"

      render_click(lv, "disable_resource_access", %{"resource_id" => resource.id})

      policy = Repo.get_by!(Policy, group_id: group.id, resource_id: resource.id)
      assert policy.disabled_at

      assert render_click(lv, "toggle_resource_access_actions", %{"resource_id" => resource.id}) =~
               "Enable"

      render_click(lv, "enable_resource_access", %{"resource_id" => resource.id})

      policy = Repo.get_by!(Policy, group_id: group.id, resource_id: resource.id)
      assert is_nil(policy.disabled_at)

      assert render_click(lv, "toggle_resource_access_actions", %{"resource_id" => resource.id}) =~
               "Remove access"

      html = render_click(lv, "confirm_remove_resource_access", %{"resource_id" => resource.id})
      assert html =~ "All group members will immediately lose access."

      render_click(lv, "remove_resource_access", %{"resource_id" => resource.id})
      assert is_nil(Repo.get_by(Policy, group_id: group.id, resource_id: resource.id))
      assert render(lv) =~ "No resource access"
    end

    test "filters and paginates members", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      actors =
        Enum.map(1..10, fn idx ->
          actor_fixture(account: account, name: "Paginated Member #{idx}")
        end) ++ [actor_fixture(account: account, name: "Unique Target Member")]

      Enum.each(actors, fn member ->
        membership_fixture(account: account, actor: member, group: group)
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}")

      assert render(lv) =~ "Page 1 of 2"

      html = render_click(lv, "next_member_page")
      assert html =~ "Page 2 of 2"

      html =
        render_change(element(lv, "form[phx-change='filter_show_members']"), %{
          "filter" => "Unique Target"
        })

      assert html =~ "Unique Target Member"
      refute html =~ "Paginated Member 1"

      html = render_click(lv, "prev_member_page")
      assert html =~ "Unique Target Member"
    end

    test "managed everyone group cannot be edited", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = managed_group_fixture(account: account, name: "Everyone", idp_id: nil)
      conn = authorize_conn(conn, actor)

      {:ok, _lv, html} = live(conn, ~p"/#{account}/groups/#{group}")

      refute html =~ "Delete group"
      refute html =~ " Edit"

      assert live(conn, ~p"/#{account}/groups/#{group}/edit") ==
               {:error,
                {:live_redirect,
                 %{
                   to: ~p"/#{account}/groups/#{group.id}",
                   flash: %{"error" => "This group cannot be edited"}
                 }}}
    end
  end

  describe ":edit action" do
    test "renders edit form with group name pre-populated", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}/edit")

      assert html =~ group.name
      assert html =~ "Group Name"
    end

    test "adds and removes memberships on save", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      current_member = actor_fixture(account: account, name: "Current Member")
      added_member = actor_fixture(account: account, name: "Added Member")
      membership_fixture(account: account, actor: current_member, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}/edit")

      html =
        lv
        |> form("#group-form", group: %{name: group.name, member_search: "Added Member"})
        |> render_change()

      assert html =~ added_member.name

      html = render_click(lv, "add_member", %{"actor_id" => added_member.id})
      assert html =~ "To Add"

      html = render_click(lv, "remove_member", %{"actor_id" => current_member.id})
      assert html =~ "To Remove"

      lv
      |> form("#group-form", group: %{name: "Updated Group Name", member_search: ""})
      |> render_submit()

      group = Repo.get_by!(Group, id: group.id, account_id: account.id)
      assert group.name == "Updated Group Name"

      assert Repo.get_by!(Membership, group_id: group.id, actor_id: added_member.id)
      assert is_nil(Repo.get_by(Membership, group_id: group.id, actor_id: current_member.id))
    end
  end

  describe "confirm_delete_group event" do
    test "shows delete confirmation and cancel dismisses it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}")

      html = render_click(lv, "confirm_delete_group")
      assert html =~ "Delete"

      html = render_click(lv, "cancel_delete_group")
      refute html =~ "Delete this group?"
    end
  end

  describe "undo_member_removal event" do
    test "undoes pending member removal and preserves membership on save", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account, name: "Member To Keep")
      membership_fixture(account: account, actor: member, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}/edit")

      html = render_click(lv, "remove_member", %{"actor_id" => member.id})
      assert html =~ "To Remove"

      html = render_click(lv, "undo_member_removal", %{"actor_id" => member.id})
      refute html =~ "To Remove"

      lv
      |> form("#group-form", group: %{name: group.name, member_search: ""})
      |> render_submit()

      assert Repo.get_by!(Membership, group_id: group.id, actor_id: member.id)
    end
  end

  describe "delete event" do
    test "deletes group and removes from list", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group}")

      render_click(lv, "delete", %{"id" => group.id})

      html = render(lv)
      refute html =~ group.name
    end
  end
end
