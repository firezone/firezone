defmodule Domain.Events.Hooks.Policies do
  @behaviour Domain.Events.Hooks
  alias Domain.{Policies, PubSub}
  require Logger

  @impl true
  def on_insert(data) do
    policy = Domain.struct_from_params(Policies.Policy, data)
    PubSub.Account.broadcast(policy.account_id, {:created, policy})
  end

  @impl true

  # Enable - process as insert
  def on_update(%{"disabled_at" => disabled_at}, %{"disabled_at" => nil} = data)
      when not is_nil(disabled_at) do
    on_insert(data)
  end

  # Disable - process as delete
  def on_update(%{"disabled_at" => nil} = old_data, %{"disabled_at" => disabled_at})
      when not is_nil(disabled_at) do
    on_delete(old_data)
  end

  # Soft-delete - process as delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Breaking update - easier for consumers to process as delete then create
  def on_update(
        %{
          "actor_group_id" => old_actor_group_id,
          "resource_id" => old_resource_id,
          "conditions" => old_conditions
        } = old_data,
        %{
          "actor_group_id" => actor_group_id,
          "resource_id" => resource_id,
          "conditions" => conditions
        } = data
      )
      when old_actor_group_id != actor_group_id or old_resource_id != resource_id or
             old_conditions != conditions do
    # Only act upon this if the policy is not deleted or disabled
    if is_nil(data["deleted_at"]) and is_nil(data["disabled_at"]) do
      on_delete(old_data)
      on_insert(data)
    end
  end

  # Regular update
  def on_update(old_data, data) do
    old_policy = Domain.struct_from_params(Policies.Policy, old_data)
    policy = Domain.struct_from_params(Policies.Policy, data)
    PubSub.Account.broadcast(policy.account_id, {:updated, old_policy, policy})
  end

  @impl true
  def on_delete(old_data) do
    policy = Domain.struct_from_params(Policies.Policy, old_data)
    PubSub.Account.broadcast(policy.account_id, {:deleted, policy})
  end
end
