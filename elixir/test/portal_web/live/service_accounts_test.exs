defmodule PortalWeb.ServiceAccountsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe ":edit action" do
    test "shows current groups for a service account in the current column", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = actor_fixture(account: account, type: :service_account)
      current_group = group_fixture(account: account, name: "Current Group")
      membership_fixture(actor: service_account, group: current_group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      assert render(lv) =~ current_group.name

      assert has_element?(
               lv,
               "button[phx-click='add_pending_group_removal'][phx-value-group_id='#{current_group.id}']"
             )
    end

    test "adds a group membership to a service account on save", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = actor_fixture(account: account, type: :service_account)
      group = group_fixture(account: account, name: "New Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      lv
      |> element("input[placeholder='Search to add groups...']")
      |> render_change(%{"value" => group.name})

      render_click(lv, "add_pending_group", %{"group_id" => group.id})

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      assert Portal.Repo.get_by(Portal.Membership,
               actor_id: service_account.id,
               group_id: group.id
             )

      render_click(lv, "change_tab", %{"tab" => "groups"})
      assert render(lv) =~ group.name
    end

    test "removes a group membership from a service account on save", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = actor_fixture(account: account, type: :service_account)
      group = group_fixture(account: account, name: "Current Group")
      membership_fixture(actor: service_account, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      render_click(lv, "add_pending_group_removal", %{"group_id" => group.id})

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      refute Portal.Repo.get_by(Portal.Membership,
               actor_id: service_account.id,
               group_id: group.id
             )
    end

    test "shows error flash when adding a group membership to a service account fails", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = actor_fixture(account: account, type: :service_account)
      group = group_fixture(account: account, name: "Target Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      lv
      |> element("input[placeholder='Search to add groups...']")
      |> render_change(%{"value" => group.name})

      render_click(lv, "add_pending_group", %{"group_id" => group.id})

      # Create the membership directly in the DB to cause a unique constraint failure on save
      membership_fixture(actor: service_account, group: group)

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      assert render(lv) =~ "Failed to update some group memberships."
    end
  end
end
