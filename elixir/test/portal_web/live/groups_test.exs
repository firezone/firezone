defmodule PortalWeb.Live.GroupsTest do
  use PortalWeb.ConnCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "edit group save" do
    test "preserves existing membership IDs when adding a new member", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      member1 = actor_fixture(account: account)
      member2 = actor_fixture(account: account)
      m1 = membership_fixture(actor: member1, group: group, account: account)
      m2 = membership_fixture(actor: member2, group: group, account: account)

      original_ids = MapSet.new([m1.id, m2.id])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      new_member = actor_fixture(account: account)
      render_click(lv, "add_member", %{"actor_id" => new_member.id})

      lv
      |> element("form#group-form")
      |> render_submit(%{"group" => %{"name" => group.name}})

      memberships =
        from(m in Portal.Membership, where: m.group_id == ^group.id)
        |> Repo.all()

      assert length(memberships) == 3

      current_ids = MapSet.new(Enum.map(memberships, & &1.id))
      assert MapSet.subset?(original_ids, current_ids)

      new_membership = Enum.find(memberships, &(&1.actor_id == new_member.id))
      assert new_membership
      refute MapSet.member?(original_ids, new_membership.id)
    end

    test "preserves existing membership IDs when removing a member", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      member1 = actor_fixture(account: account)
      member2 = actor_fixture(account: account)
      member3 = actor_fixture(account: account)
      m1 = membership_fixture(actor: member1, group: group, account: account)
      m2 = membership_fixture(actor: member2, group: group, account: account)
      _m3 = membership_fixture(actor: member3, group: group, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      render_click(lv, "remove_member", %{"actor_id" => member3.id})

      lv
      |> element("form#group-form")
      |> render_submit(%{"group" => %{"name" => group.name}})

      memberships =
        from(m in Portal.Membership, where: m.group_id == ^group.id)
        |> Repo.all()

      assert length(memberships) == 2

      remaining_ids = MapSet.new(Enum.map(memberships, & &1.id))
      assert MapSet.equal?(remaining_ids, MapSet.new([m1.id, m2.id]))
    end

    test "no-op save with unchanged members issues no membership deletes or inserts", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      member1 = actor_fixture(account: account)
      member2 = actor_fixture(account: account)
      m1 = membership_fixture(actor: member1, group: group, account: account)
      m2 = membership_fixture(actor: member2, group: group, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      # Submit without any membership changes (just rename)
      lv
      |> element("form#group-form")
      |> render_submit(%{"group" => %{"name" => "Renamed Group"}})

      memberships =
        from(m in Portal.Membership, where: m.group_id == ^group.id)
        |> Repo.all()

      assert length(memberships) == 2

      remaining_ids = MapSet.new(Enum.map(memberships, & &1.id))
      assert MapSet.equal?(remaining_ids, MapSet.new([m1.id, m2.id]))
    end
  end

  describe "groups list" do
    test "redirects unauthorized users to sign-in", %{account: account, conn: conn} do
      path = ~p"/#{account}/groups"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end

    test "renders breadcrumbs", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups")

      assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
      breadcrumbs = String.trim(Floki.text(item))
      assert breadcrumbs =~ "Groups"
    end

    test "renders groups table with name and members columns", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account, name: "Engineering Team")
      member = actor_fixture(account: account)
      membership_fixture(actor: member, group: group, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups")

      rows =
        lv
        |> element("#groups")
        |> render()
        |> table_to_map()

      with_table_row(rows, "group", group.name, fn row ->
        assert row["members"] == "1"
      end)
    end

    test "renders Add Group button", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups")

      assert html =~ "Add Group"
    end
  end

  describe "group show" do
    test "renders group name in modal title", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account, name: "My Special Group")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}")

      assert html =~ "My Special Group"
    end

    test "renders group details section", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}")

      assert html =~ group.id
      assert html =~ "Details"
    end

    test "renders members list for group with members", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account)
      membership_fixture(actor: member, group: group, account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}")

      assert html =~ member.name
    end

    test "renders empty members message when group has no members", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}")

      assert html =~ "No members in this group."
    end
  end

  describe "add group" do
    test "renders the add group form", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/add")

      assert html =~ "Add Group"
      assert html =~ "Group Name"
    end

    test "disables confirm button when name field is empty", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/add")

      html =
        lv
        |> element("form#group-form")
        |> render_change(%{"group" => %{"name" => ""}})

      # The confirm button is disabled when form is invalid (empty name leaves changeset invalid
      # because the LV changeset does not mark it as valid without a name value)
      assert html =~ "disabled"
    end

    test "creates a new group successfully", %{account: account, actor: actor, conn: conn} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/add")

      lv
      |> element("form#group-form")
      |> render_submit(%{"group" => %{"name" => "New Test Group"}})

      assert render(lv) =~ "Group created successfully"
    end
  end

  describe "edit group" do
    test "renders edit form with current group name", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account, name: "Original Name")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      assert html =~ "Edit #{group.name}"
      assert html =~ "Original Name"
    end

    test "saves name change successfully", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account, name: "Old Name")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      lv
      |> element("form#group-form")
      |> render_submit(%{"group" => %{"name" => "New Name"}})

      html = render(lv)
      assert html =~ "Group updated successfully"
    end

    test "disables confirm button when name field is cleared", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account, name: "Some Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      html =
        lv
        |> element("form#group-form")
        |> render_change(%{"group" => %{"name" => ""}})

      # Confirm button is disabled when form is not valid
      assert html =~ "disabled"
    end

    test "redirects to show when trying to edit a non-editable group", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # A managed group with an idp_id is not editable
      group = group_fixture(account: account, type: :managed, idp_id: "some-idp-id")

      assert {:error,
              {:live_redirect,
               %{
                 to: _,
                 flash: %{"error" => "This group cannot be edited"}
               }}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/groups/#{group.id}/edit")
    end
  end

  describe "handle_event delete" do
    test "deletes a group successfully", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account, name: "Group To Delete")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}")

      render_click(lv, "delete", %{"id" => group.id})

      html = render(lv)
      assert html =~ "Group deleted successfully"
      refute html =~ "Group To Delete"
    end

    test "shows error when attempting to delete a non-deletable group (Everyone)", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # "Everyone" group cannot be deleted
      everyone_group =
        group_fixture(account: account, name: "Everyone", type: :managed)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{everyone_group.id}")

      render_click(lv, "delete", %{"id" => everyone_group.id})

      html = render(lv)
      assert html =~ "This group cannot be deleted"
    end
  end

  describe "member search filtering" do
    test "excludes existing group members from search results", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      existing_member = actor_fixture(account: account, name: "UniqueExistingMember")
      membership_fixture(actor: existing_member, group: group, account: account)

      non_member = actor_fixture(account: account, name: "UniqueNonMember")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      # Search for existing member - should not appear in search results dropdown
      lv
      |> element("form#group-form")
      |> render_change(%{
        "group" => %{"name" => group.name, "member_search" => "UniqueExistingMember"}
      })

      refute has_element?(
               lv,
               ~s(button[phx-click=add_member][phx-value-actor_id="#{existing_member.id}"])
             )

      # Search for non-member - should appear in search results dropdown
      lv
      |> element("form#group-form")
      |> render_change(%{
        "group" => %{"name" => group.name, "member_search" => "UniqueNonMember"}
      })

      assert has_element?(
               lv,
               ~s(button[phx-click=add_member][phx-value-actor_id="#{non_member.id}"])
             )
    end

    test "excludes pending additions from search results", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      new_member = actor_fixture(account: account, name: "UniquePendingMember")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      # Add the member (but don't save yet)
      render_click(lv, "add_member", %{"actor_id" => new_member.id})

      # Search for the same member again - should not appear in search results
      lv
      |> element("form#group-form")
      |> render_change(%{
        "group" => %{"name" => group.name, "member_search" => "UniquePendingMember"}
      })

      refute has_element?(
               lv,
               ~s(button[phx-click=add_member][phx-value-actor_id="#{new_member.id}"])
             )
    end

    test "members pending removal reappear in search results", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account, name: "UniqueRemovableMember")
      membership_fixture(actor: member, group: group, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/groups/#{group.id}/edit")

      # Member is currently in group - should not appear in search
      lv
      |> element("form#group-form")
      |> render_change(%{
        "group" => %{"name" => group.name, "member_search" => "UniqueRemovableMember"}
      })

      refute has_element?(
               lv,
               ~s(button[phx-click=add_member][phx-value-actor_id="#{member.id}"])
             )

      # Mark member for removal
      render_click(lv, "remove_member", %{"actor_id" => member.id})

      # Clear search to reset cached results, then search again
      lv
      |> element("form#group-form")
      |> render_change(%{"group" => %{"name" => group.name, "member_search" => ""}})

      lv
      |> element("form#group-form")
      |> render_change(%{
        "group" => %{"name" => group.name, "member_search" => "UniqueRemovableMember"}
      })

      assert has_element?(
               lv,
               ~s(button[phx-click=add_member][phx-value-actor_id="#{member.id}"])
             )
    end
  end
end
