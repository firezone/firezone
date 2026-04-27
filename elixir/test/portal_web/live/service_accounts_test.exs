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
  end
end
