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

  # Regular update
  def on_update(old_data, data) do
    old_policy = SchemaHelpers.struct_from_params(Policies.Policy, old_data)
    policy = SchemaHelpers.struct_from_params(Policies.Policy, data)
    PubSub.Account.broadcast(policy.account_id, {:updated, old_policy, policy})
  end

  @impl true
  def on_delete(old_data) do
    policy = SchemaHelpers.struct_from_params(Policies.Policy, old_data)
    PubSub.Account.broadcast(policy.account_id, {:deleted, policy})
  end
end
