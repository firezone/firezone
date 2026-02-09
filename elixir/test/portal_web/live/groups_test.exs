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
