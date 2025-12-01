defmodule Domain.Changes.Hooks.PoliciesTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.Policies
  alias Domain.{Changes.Change, Policies, PubSub}

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
        "disabled_at" => nil
      }

      assert :ok == on_insert(0, data)
      assert_receive %Change{op: :insert, struct: %Domain.Policy{} = policy, lsn: 0}

      assert policy.id == data["id"]
      assert policy.account_id == data["account_id"]
      assert policy.actor_group_id == data["actor_group_id"]
      assert policy.resource_id == data["resource_id"]
    end
  end

  describe "update/2" do
    test "disable policy broadcasts deleted policy and deletes flows" do
      account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: account)
      policy = Fixtures.Policies.create_policy(account: account, resource: resource)
      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "disabled_at" => nil
      }

      data = Map.put(old_data, "disabled_at", "2023-10-01T00:00:00Z")

      # Create a flow that should be deleted
      flow = Fixtures.Flows.create_flow(policy: policy, resource: resource, account: account)

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Domain.Policy{} = broadcasted_policy,
        lsn: 0
      }

      assert broadcasted_policy.id == data["id"]
      assert broadcasted_policy.account_id == data["account_id"]

      # Verify flow was deleted
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

    test "enable policy broadcasts created policy" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)
      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "disabled_at" => "2023-09-01T00:00:00Z"
      }

      data = Map.put(old_data, "disabled_at", nil)

      assert :ok == on_update(0, old_data, data)
      assert_receive %Change{op: :insert, struct: %Domain.Policy{} = policy, lsn: 0}

      assert policy.id == data["id"]
      assert policy.account_id == data["account_id"]
      assert policy.actor_group_id == data["actor_group_id"]
      assert policy.resource_id == data["resource_id"]
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
        "disabled_at" => nil
      }

      data = Map.put(old_data, "description", "Updated description")

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Domain.Policy{} = old_policy,
        struct: %Domain.Policy{} = new_policy,
        lsn: 0
      }

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
        "resource_id" => policy.resource_id
      }

      data = Map.put(old_data, "resource_id", "00000000-0000-0000-0000-000000000001")

      assert flow =
               Fixtures.Flows.create_flow(
                 policy: policy,
                 account: account
               )

      assert :ok = on_update(0, old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

    test "breaking update on actor_group_id deletes flows" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id
      }

      data = Map.put(old_data, "actor_group_id", "00000000-0000-0000-0000-000000000001")

      assert flow = Fixtures.Flows.create_flow(policy: policy, account: account)

      assert :ok = on_update(0, old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

    test "breaking update on conditions deletes flows" do
      account = Fixtures.Accounts.create_account()
      policy = Fixtures.Policies.create_policy(account: account)

      old_data = %{
        "id" => policy.id,
        "account_id" => account.id,
        "actor_group_id" => policy.actor_group_id,
        "resource_id" => policy.resource_id,
        "conditions" => [
          %{"property" => "remote_ip", "operator" => "is_in", "values" => ["10.0.0.1"]}
        ]
      }

      data =
        Map.put(old_data, "conditions", [
          %{"property" => "remote_ip", "operator" => "is_in", "values" => ["10.0.0.2"]}
        ])

      assert flow = Fixtures.Flows.create_flow(policy: policy, account: account)

      assert :ok = on_update(0, old_data, data)
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

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Domain.Policy{} = policy,
        lsn: 0
      }

      assert policy.id == old_data["id"]
      assert policy.account_id == old_data["account_id"]
      assert policy.actor_group_id == old_data["actor_group_id"]
      assert policy.resource_id == old_data["resource_id"]
    end
  end
end
