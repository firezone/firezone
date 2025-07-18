defmodule Domain.Events.Hooks.ActorGroupMembershipsTest do
  use API.ChannelCase, async: true
  import Domain.Events.Hooks.ActorGroupMemberships
  alias Domain.Actors
  alias Domain.PubSub

  describe "insert/1" do
    test "broadcasts membership" do
      account_id = "00000000-0000-0000-0000-000000000001"
      actor_id = "00000000-0000-0000-0000-000000000002"
      group_id = "00000000-0000-0000-0000-000000000003"

      :ok = PubSub.Account.subscribe(account_id)

      data = %{
        "account_id" => account_id,
        "actor_id" => actor_id,
        "group_id" => group_id
      }

      assert :ok == on_insert(data)
      assert_receive {:created, %Actors.Membership{} = membership}
      assert membership.account_id == account_id
      assert membership.actor_id == actor_id
      assert membership.group_id == group_id
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok == on_update(%{}, %{})
    end
  end

  describe "delete/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor_group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)

      membership =
        Fixtures.Actors.create_membership(account: account, group: actor_group, actor: actor)

      %{
        account: account,
        actor_group: actor_group,
        actor: actor,
        membership: membership
      }
    end

    test "broadcasts deleted membership" do
      account_id = "00000000-0000-0000-0000-000000000001"
      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000000",
        "account_id" => "00000000-0000-0000-0000-000000000001",
        "actor_id" => "00000000-0000-0000-0000-000000000002",
        "group_id" => "00000000-0000-0000-0000-000000000003"
      }

      assert :ok == on_delete(old_data)

      assert_receive {:deleted, %Actors.Membership{} = membership}
      assert membership.id == "00000000-0000-0000-0000-000000000000"
      assert membership.account_id == "00000000-0000-0000-0000-000000000001"
      assert membership.actor_id == "00000000-0000-0000-0000-000000000002"
      assert membership.group_id == "00000000-0000-0000-0000-000000000003"
    end

    test "deletes flows for membership", %{account: account, membership: membership} do
      flow = Fixtures.Flows.create_flow(account: account, actor_group_membership: membership)
      unrelated_flow = Fixtures.Flows.create_flow(account: account)

      old_data = %{
        "id" => membership.id,
        "account_id" => membership.account_id,
        "actor_id" => membership.actor_id,
        "group_id" => membership.group_id
      }

      assert ^flow = Repo.get_by(Domain.Flows.Flow, actor_group_membership_id: membership.id)
      assert :ok == on_delete(old_data)
      assert nil == Repo.get_by(Domain.Flows.Flow, actor_group_membership_id: membership.id)
      assert ^unrelated_flow = Repo.get_by(Domain.Flows.Flow, id: unrelated_flow.id)
    end
  end
end
