defmodule Domain.Events.Hooks.PoliciesTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Policies
  alias Domain.Events

  describe "insert/1" do
    test "broadcasts :create_policy and :allow_access" do
      policy_id = "policy-123"
      account_id = "account-456"
      actor_group_id = "group-456"
      resource_id = "resource-789"

      data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id
      }

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_insert(data)
      assert_receive {:create_policy, ^policy_id}
      assert_receive {:create_policy, ^policy_id}
      assert_receive {:allow_access, ^policy_id, ^actor_group_id, ^resource_id}
    end
  end

  describe "update/2" do
    test "enable: broadcasts :enable_policy and :allow_access" do
      policy_id = "policy-123"
      account_id = "account-456"
      actor_group_id = "group-456"
      resource_id = "resource-789"

      old_data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "disabled_at" => "2023-10-01T00:00:00Z"
      }

      data = Map.put(old_data, "disabled_at", nil)

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)
      assert_receive {:enable_policy, ^policy_id}
      assert_receive {:enable_policy, ^policy_id}
      assert_receive {:allow_access, ^policy_id, ^actor_group_id, ^resource_id}
    end

    test "disable: broadcasts :disable_policy and :reject_access" do
      flow = Fixtures.Flows.create_flow()
      policy_id = flow.policy_id
      account_id = flow.account_id
      actor_group_id = "group-456"
      resource_id = flow.resource_id

      old_data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "disabled_at" => nil
      }

      data = Map.put(old_data, "disabled_at", "2023-10-01T00:00:00Z")

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)
      assert_receive {:disable_policy, ^policy_id}
      assert_receive {:disable_policy, ^policy_id}
      assert_receive {:reject_access, ^policy_id, ^actor_group_id, ^resource_id}

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)

      flow = Repo.reload(flow)

      assert DateTime.compare(flow.expires_at, DateTime.utc_now()) == :lt
    end

    test "soft-delete: broadcasts :delete_policy and :reject_access" do
      flow = Fixtures.Flows.create_flow()
      policy_id = flow.policy_id
      account_id = flow.account_id
      actor_group_id = "group-456"
      resource_id = flow.resource_id

      old_data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)
      assert_receive {:delete_policy, ^policy_id}
      assert_receive {:delete_policy, ^policy_id}
      assert_receive {:reject_access, ^policy_id, ^actor_group_id, ^resource_id}

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)

      flow = Repo.reload(flow)

      assert DateTime.compare(flow.expires_at, DateTime.utc_now()) == :lt
    end

    test "breaking update: broadcasts :delete_policy, :reject_access, :create_policy, :allow_access" do
      flow = Fixtures.Flows.create_flow()
      policy_id = flow.policy_id
      account_id = flow.account_id
      actor_group_id = "group-456"
      resource_id = flow.resource_id

      old_data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "conditions" => []
      }

      data = Map.put(old_data, "resource_id", "new-resource-123")

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)

      assert_receive {:delete_policy, ^policy_id}
      assert_receive {:delete_policy, ^policy_id}
      assert_receive {:reject_access, ^policy_id, ^actor_group_id, ^resource_id}

      assert_receive {:create_policy, ^policy_id}
      assert_receive {:create_policy, ^policy_id}
      assert_receive {:allow_access, ^policy_id, ^actor_group_id, "new-resource-123"}

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)

      flow = Repo.reload(flow)

      assert DateTime.compare(flow.expires_at, DateTime.utc_now()) == :lt
    end

    test "breaking update: disabled policy has no side-effects" do
      flow = Fixtures.Flows.create_flow()
      policy_id = flow.policy_id
      account_id = flow.account_id
      actor_group_id = "group-456"
      resource_id = flow.resource_id

      old_data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "disabled_at" => "2023-10-01T00:00:00Z"
      }

      data = Map.put(old_data, "resource_id", "new-resource-123")

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)

      refute_receive {:delete_policy, ^policy_id}
      refute_receive {:reject_access, ^policy_id, ^actor_group_id, ^resource_id}
      refute_receive {:create_policy, ^policy_id}
      refute_receive {:allow_access, ^policy_id, ^actor_group_id, "new-resource-123"}

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)

      flow = Repo.reload(flow)

      assert DateTime.compare(flow.expires_at, DateTime.utc_now()) == :gt
    end

    test "non-breaking-update: broadcasts :update_policy" do
      policy_id = "policy-123"
      account_id = "account-456"
      actor_group_id = "group-456"
      resource_id = "resource-789"

      old_data = %{
        "description" => "Old Policy",
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "disabled_at" => "2023-10-01T00:00:00Z"
      }

      data = Map.put(old_data, "resource_id", "new-resource-123")

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)

      assert_receive {:update_policy, ^policy_id}
      assert_receive {:update_policy, ^policy_id}
    end
  end

  describe "delete/1" do
    test "broadcasts :delete_policy and :reject_access" do
      flow = Fixtures.Flows.create_flow()
      policy_id = flow.policy_id
      account_id = flow.account_id
      actor_group_id = "group-456"
      resource_id = flow.resource_id

      old_data = %{
        "id" => policy_id,
        "account_id" => account_id,
        "actor_group_id" => actor_group_id,
        "resource_id" => resource_id,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      :ok = subscribe(policy_id)
      :ok = Events.Hooks.Accounts.subscribe_to_policies(account_id)
      :ok = Events.Hooks.ActorGroups.subscribe_to_policies(actor_group_id)

      assert :ok == on_update(old_data, data)
      assert_receive {:delete_policy, ^policy_id}
      assert_receive {:delete_policy, ^policy_id}
      assert_receive {:reject_access, ^policy_id, ^actor_group_id, ^resource_id}

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)

      flow = Repo.reload(flow)

      assert DateTime.compare(flow.expires_at, DateTime.utc_now()) == :lt
    end
  end
end
