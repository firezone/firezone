defmodule Portal.Changes.Hooks.MembershipsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Memberships
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  alias Portal.Changes.Change
  alias Portal.Membership
  alias Portal.PolicyAuthorization
  alias Portal.PubSub

  describe "insert/1" do
    test "broadcasts membership" do
      account_id = "00000000-0000-0000-0000-000000000001"
      actor_id = "00000000-0000-0000-0000-000000000002"
      group_id = "00000000-0000-0000-0000-000000000003"

      :ok = PubSub.Changes.subscribe(account_id, :memberships)

      data = %{
        "account_id" => account_id,
        "actor_id" => actor_id,
        "group_id" => group_id
      }

      assert :ok == on_insert(0, data)
      assert_receive %Change{op: :insert, struct: %Membership{} = membership, lsn: 0}
      assert membership.account_id == account_id
      assert membership.actor_id == actor_id
      assert membership.group_id == group_id
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok == on_update(0, %{}, %{})
    end
  end

  describe "delete/1" do
    test "deletes the authorizations toward the actor's devices through the group's pools" do
      account = account_fixture()
      group = group_fixture(account: account)
      leaver = actor_fixture(account: account)
      stayer = actor_fixture(account: account)
      membership = membership_fixture(account: account, actor: leaver, group: group)
      membership_fixture(account: account, actor: stayer, group: group)
      initiator = client_fixture(account: account)
      leaving = client_fixture(account: account, actor: leaver)
      staying = client_fixture(account: account, actor: stayer)
      pool = actor_group_pool_resource_fixture(account: account, group: group)
      other_pool = actor_group_pool_resource_fixture(account: account, group: group_fixture(account: account))

      leaving_pa =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: leaving)

      staying_pa =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: staying)

      other_pa =
        policy_authorization_fixture(account: account, resource: other_pool, client: initiator, gateway: leaving)

      old_data = %{
        "id" => membership.id,
        "account_id" => account.id,
        "actor_id" => leaver.id,
        "group_id" => group.id
      }

      assert :ok == on_delete(0, old_data)
      refute Repo.get_by(PolicyAuthorization, id: leaving_pa.id)
      assert Repo.get_by(PolicyAuthorization, id: staying_pa.id)
      assert Repo.get_by(PolicyAuthorization, id: other_pa.id)
    end

    test "broadcasts deleted membership" do
      account_id = "00000000-0000-0000-0000-000000000001"
      :ok = PubSub.Changes.subscribe(account_id, :memberships)

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000000",
        "account_id" => "00000000-0000-0000-0000-000000000001",
        "actor_id" => "00000000-0000-0000-0000-000000000002",
        "group_id" => "00000000-0000-0000-0000-000000000003"
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Membership{} = membership,
        lsn: 0
      }

      assert membership.id == "00000000-0000-0000-0000-000000000000"
      assert membership.account_id == "00000000-0000-0000-0000-000000000001"
      assert membership.actor_id == "00000000-0000-0000-0000-000000000002"
      assert membership.group_id == "00000000-0000-0000-0000-000000000003"
    end
  end
end
