defmodule Domain.Events.Hooks.PoliciesTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Policies
  alias Domain.{Policies, PubSub}

  describe "insert/1" do
    test "broadcasts created policy" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)
      :ok = PubSub.Account.subscribe(account.id)

      data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "disabled_at" => nil,
        "deleted_at" => nil
      }

      assert :ok == on_insert(data)
      assert_receive {:created, %Policies.Policy{} = policy}

      assert policy.id == data["id"]
      assert policy.account_id == data["account_id"]
      assert policy.actor_group_id == data["actor_group_id"]
      assert policy.resource_id == data["resource_id"]
    end
  end

  describe "update/2" do
    test "soft-delete broadcasts deleted policy" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)
      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "disabled_at" => nil,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      assert :ok == on_update(old_data, data)
      assert_receive {:deleted, %Policies.Policy{} = policy}

      assert policy.id == old_data["id"]
      assert policy.account_id == old_data["account_id"]
      assert policy.actor_group_id == old_data["actor_group_id"]
      assert policy.resource_id == old_data["resource_id"]
    end

    test "soft-delete deletes flows" do
      account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        )

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => resource.id,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      assert flow =
               Fixtures.Flows.create_flow(
                 policy: policy,
                 resource: resource,
                 account: account
               )

      assert :ok = on_update(old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

    test "non-breaking update broadcasts updated policy" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)
      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => policy.id,
        "description" => "Old description",
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "disabled_at" => nil,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "description", "Updated description")

      assert :ok == on_update(old_data, data)
      assert_receive {:updated, %Policies.Policy{} = old_policy, %Policies.Policy{} = new_policy}
      assert old_policy.id == old_data["id"]
      assert new_policy.description == data["description"]
      assert new_policy.account_id == old_data["account_id"]
      assert new_policy.actor_group_id == old_data["actor_group_id"]
      assert new_policy.resource_id == old_data["resource_id"]
    end

    test "breaking update deletes flows" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "resource_id", "00000000-0000-0000-0000-000000000001")

      assert flow =
               Fixtures.Flows.create_flow(
                 policy: policy,
                 account: account
               )

      assert :ok = on_update(old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end

  describe "delete/1" do
    test "broadcasts deleted policy" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)
      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id
      }

      assert :ok == on_delete(old_data)
      assert_receive {:deleted, %Policies.Policy{} = policy}

      assert policy.id == old_data["id"]
      assert policy.account_id == old_data["account_id"]
      assert policy.actor_group_id == old_data["actor_group_id"]
      assert policy.resource_id == old_data["resource_id"]
    end

    test "deletes flows" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "deleted_at" => nil
      }

      assert flow = Fixtures.Flows.create_flow(policy: policy, account: account)

      assert :ok = on_delete(old_data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end
end
