defmodule Domain.Events.Hooks.Policies do
  @behaviour Domain.Events.Hooks
  alias Domain.{Policies, PubSub, SchemaHelpers}
  require Logger

  @impl true
  def on_insert(data) do
    policy = SchemaHelpers.struct_from_params(Policies.Policy, data)
    PubSub.Account.broadcast(policy.account_id, {:created, policy})
  end

  @impl true

  # Disable - process as delete
  def on_update(%{"disabled_at" => nil}, %{"disabled_at" => disabled_at} = data)
      when not is_nil(disabled_at) do
    on_delete(data)
  end

  # Enable - process as insert
  def on_update(%{"disabled_at" => disabled_at}, %{"disabled_at" => nil} = data)
      when not is_nil(disabled_at) do
    on_insert(data)
  end

  # Soft-delete - process as delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(old_data, data) do
    old_policy = SchemaHelpers.struct_from_params(Policies.Policy, old_data)
    policy = SchemaHelpers.struct_from_params(Policies.Policy, data)

    # Breaking updates
    # This is a special case - we need to delete related flows because connectivity has changed
    # The Gateway PID will receive flow deletion messages and process them to potentially reject
    # access. The client PID (if connected) will toggle the resource deleted/created.
    if old_policy.conditions != policy.conditions or
         old_policy.actor_group_id != policy.actor_group_id or
         old_policy.resource_id != policy.resource_id do
      Domain.Flows.delete_flows_for(policy)
    end

    PubSub.Account.broadcast(policy.account_id, {:updated, old_policy, policy})
  end

  @impl true
  def on_delete(old_data) do
    policy = SchemaHelpers.struct_from_params(Policies.Policy, old_data)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(policy)

    PubSub.Account.broadcast(policy.account_id, {:deleted, policy})
  end
end
