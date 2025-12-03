defmodule Domain.Changes.Hooks.Policies do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Policy, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    policy = struct_from_params(Policy, data)
    change = %Change{lsn: lsn, op: :insert, struct: policy}

    PubSub.Account.broadcast(policy.account_id, change)
  end

  @impl true

  # Disable - process as delete
  def on_update(lsn, %{"disabled_at" => nil} = old_data, %{"disabled_at" => disabled_at})
      when not is_nil(disabled_at) do
    # TODO: Potentially revisit whether this should be handled here
    #       or handled closer to where the PubSub message is received.
    policy = struct_from_params(Policy, old_data)
    delete_policy_authorizations_for(policy)

    on_delete(lsn, old_data)
  end

  # Enable - process as insert
  def on_update(lsn, %{"disabled_at" => disabled_at}, %{"disabled_at" => nil} = data)
      when not is_nil(disabled_at) do
    on_insert(lsn, data)
  end

  # Regular update
  def on_update(lsn, old_data, data) do
    old_policy = struct_from_params(Policy, old_data)
    policy = struct_from_params(Policy, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_policy, struct: policy}

    # Breaking updates
    # This is a special case - we need to delete related policy_authorizations because connectivity has changed
    # The Gateway PID will receive policy_authorization deletion messages and process them to potentially reject
    # access. The client PID (if connected) will toggle the resource deleted/created.
    if old_policy.conditions != policy.conditions or
         old_policy.group_id != policy.group_id or
         old_policy.resource_id != policy.resource_id do
      delete_policy_authorizations_for(old_policy)
    end

    PubSub.Account.broadcast(policy.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    policy = struct_from_params(Policy, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: policy}

    PubSub.Account.broadcast(policy.account_id, change)
  end

  # Inline function from Domain.PolicyAuthorizations
  defp delete_policy_authorizations_for(%Policy{} = policy) do
    import Ecto.Query

    from(f in Domain.PolicyAuthorization, as: :policy_authorizations)
    |> where([policy_authorizations: f], f.account_id == ^policy.account_id)
    |> where([policy_authorizations: f], f.policy_id == ^policy.id)
    |> Domain.Safe.unscoped()
    |> Domain.Safe.delete_all()
  end
end
