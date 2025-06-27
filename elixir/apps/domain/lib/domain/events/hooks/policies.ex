defmodule Domain.Events.Hooks.Policies do
  @behaviour Domain.Events.Hooks
  alias Domain.{Flows, PubSub}
  require Logger

  @impl true
  def on_insert(
        %{
          "id" => policy_id,
          "account_id" => account_id,
          "actor_group_id" => actor_group_id,
          "resource_id" => resource_id
        } =
          _data
      ) do
    # TODO: WAL
    # Creating a policy should broadcast directly to subscribed clients/gateways
    payload = {:create_policy, policy_id}
    :ok = PubSub.Policy.broadcast(policy_id, payload)
    :ok = PubSub.Account.Policies.broadcast(account_id, payload)

    payload = {:allow_access, policy_id, actor_group_id, resource_id}
    :ok = PubSub.ActorGroup.Policies.broadcast(actor_group_id, payload)
  end

  @impl true

  # Enable
  def on_update(
        %{"disabled_at" => disabled_at} = _old_data,
        %{
          "disabled_at" => nil,
          "id" => policy_id,
          "account_id" => account_id,
          "actor_group_id" => actor_group_id,
          "resource_id" => resource_id
        } = _data
      )
      when not is_nil(disabled_at) do
    # TODO: WAL
    # Enabling a policy should broadcast directly to subscribed clients/gateways
    payload = {:enable_policy, policy_id}
    :ok = PubSub.Policy.broadcast(policy_id, payload)
    :ok = PubSub.Account.Policies.broadcast(account_id, payload)

    payload = {:allow_access, policy_id, actor_group_id, resource_id}
    :ok = PubSub.ActorGroup.Policies.broadcast(actor_group_id, payload)
  end

  # Disable
  def on_update(
        %{"disabled_at" => nil} = _old_data,
        %{
          "disabled_at" => disabled_at,
          "id" => policy_id,
          "account_id" => account_id,
          "actor_group_id" => actor_group_id,
          "resource_id" => resource_id
        } = _data
      )
      when not is_nil(disabled_at) do
    Task.start(fn ->
      # TODO: WAL
      # Disabling a policy should broadcast directly to the subscribed clients/gateways
      payload = {:disable_policy, policy_id}
      :ok = PubSub.Policy.broadcast(policy_id, payload)
      :ok = PubSub.Account.Policies.broadcast(account_id, payload)

      payload = {:reject_access, policy_id, actor_group_id, resource_id}
      :ok = PubSub.ActorGroup.Policies.broadcast(actor_group_id, payload)

      # TODO: WAL
      # Broadcast flow side effects directly
      :ok = Flows.expire_flows_for_policy_id(account_id, policy_id)
    end)

    :ok
  end

  # Soft-delete
  def on_update(
        %{
          "deleted_at" => nil
        } = old_data,
        %{"deleted_at" => deleted_at} = _data
      )
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Breaking update - delete then create
  def on_update(
        %{
          "id" => old_policy_id,
          "account_id" => old_account_id,
          "actor_group_id" => old_actor_group_id,
          "resource_id" => old_resource_id,
          "conditions" => old_conditions
        } = _old_data,
        %{
          "id" => policy_id,
          "account_id" => account_id,
          "actor_group_id" => actor_group_id,
          "resource_id" => resource_id,
          "conditions" => conditions
        } = data
      )
      when old_actor_group_id != actor_group_id or old_resource_id != resource_id or
             old_conditions != conditions do
    # Only act upon this if the policy is not deleted or disabled
    if is_nil(data["deleted_at"]) and is_nil(data["disabled_at"]) do
      Task.start(fn ->
        # TODO: WAL
        # Deleting a policy should broadcast directly to the subscribed clients/gateways
        payload = {:delete_policy, old_policy_id}
        :ok = PubSub.Policy.broadcast(old_policy_id, payload)
        :ok = PubSub.Account.Policies.broadcast(old_account_id, payload)

        payload = {:reject_access, old_policy_id, old_actor_group_id, old_resource_id}
        :ok = PubSub.ActorGroup.Policies.broadcast(old_actor_group_id, payload)

        payload = {:create_policy, policy_id}
        :ok = PubSub.Policy.broadcast(policy_id, payload)
        :ok = PubSub.Account.Policies.broadcast(account_id, payload)

        payload = {:allow_access, policy_id, actor_group_id, resource_id}
        :ok = PubSub.ActorGroup.Policies.broadcast(actor_group_id, payload)

        # TODO: WAL
        # Broadcast flow side effects directly
        :ok = Flows.expire_flows_for_policy_id(account_id, policy_id)
      end)
    else
      Logger.warning("Breaking update ignored for policy as it is deleted or disabled",
        policy_id: policy_id
      )
    end

    :ok
  end

  # Regular update - name, description, etc
  def on_update(_old_data, %{"id" => policy_id, "account_id" => account_id} = _data) do
    payload = {:update_policy, policy_id}
    :ok = PubSub.Policy.broadcast(policy_id, payload)
    :ok = PubSub.Account.Policies.broadcast(account_id, payload)
  end

  @impl true
  def on_delete(
        %{
          "id" => policy_id,
          "account_id" => account_id,
          "actor_group_id" => actor_group_id,
          "resource_id" => resource_id
        } = _old_data
      ) do
    Task.start(fn ->
      # TODO: WAL
      # Deleting a policy should broadcast directly to the subscribed clients/gateways
      payload = {:delete_policy, policy_id}
      :ok = PubSub.Policy.broadcast(policy_id, payload)
      :ok = PubSub.Account.Policies.broadcast(account_id, payload)

      payload = {:reject_access, policy_id, actor_group_id, resource_id}
      :ok = PubSub.ActorGroup.Policies.broadcast(actor_group_id, payload)

      # TODO: WAL
      # Broadcast flow side effects directly
      :ok = Flows.expire_flows_for_policy_id(account_id, policy_id)
    end)

    :ok
  end
end
