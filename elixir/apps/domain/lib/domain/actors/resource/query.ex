defmodule Domain.Actors.Resource.Query do
  use Domain, :query
  alias Domain.Actors.{Actor, Membership}
  alias Domain.Policies.Policy

  def insert_for_policy_ids(policy_ids) do
    from policy in Policy,
      join: membership in Membership,
      on:
        membership.group_id == policy.actor_group_id and
          membership.account_id == policy.account_id,
      where: policy.id in ^policy_ids,
      where: is_nil(policy.deleted_at) and is_nil(policy.disabled_at),
      select: %{
        account_id: policy.account_id,
        actor_id: membership.actor_id,
        resource_id: policy.resource_id,
        inserted_at: fragment("TIMEZONE('UTC', NOW())")
      }
  end

  def delete_for_policy_ids(policy_ids) do
    from policy in Policy,
      join: membership in Membership,
      on:
        membership.group_id == policy.actor_group_id and
          membership.account_id == policy.account_id,
      where: policy.id in ^policy_ids
  end

  def insert_for_actor_ids(actor_ids) do
    from actor in Actor,
      join: membership in Membership,
      on:
        membership.actor_id == actor.id and
          membership.account_id == actor.account_id,
      join: policy in Policy,
      on: policy.actor_group_id == membership.group_id,
      where: policy.account_id == actor.account_id,
      where: is_nil(policy.deleted_at) and is_nil(policy.disabled_at),
      where: actor.id in ^actor_ids,
      select: %{
        account_id: actor.account_id,
        actor_id: actor.id,
        resource_id: policy.resource_id,
        inserted_at: fragment("TIMEZONE('UTC', NOW())")
      }
  end

  def delete_for_actor_ids(actor_ids) do
    from actor in Actor,
      join: membership in Membership,
      on:
        membership.actor_id == actor.id and
          membership.account_id == actor.account_id,
      join: policy in Policy,
      on: policy.actor_group_id == membership.group_id,
      where: policy.account_id == actor.account_id,
      where: actor.id in ^actor_ids
  end

  def insert_for_actor_group_ids(actor_group_ids) do
    from membership in Membership,
      join: policy in Policy,
      on: policy.actor_group_id == membership.group_id,
      where: policy.account_id == membership.account_id,
      where: is_nil(policy.deleted_at) and is_nil(policy.disabled_at),
      where: membership.group_id in ^actor_group_ids,
      select: %{
        account_id: membership.account_id,
        actor_id: membership.actor_id,
        resource_id: policy.resource_id,
        inserted_at: fragment("TIMEZONE('UTC', NOW())")
      }
  end

  def delete_for_actor_group_ids(actor_group_ids) do
    from membership in Membership,
      join: policy in Policy,
      on: policy.actor_group_id == membership.group_id,
      where: policy.account_id == membership.account_id,
      where: membership.group_id in ^actor_group_ids
  end

  def insert_for_memberships(account_id, tuples) do
    dynamic_query =
      Enum.reduce(tuples, dynamic(true), fn {group_id, actor_id}, acc ->
        dynamic([m], (m.group_id == ^group_id and m.actor_id == ^actor_id) or ^acc)
      end)

    from membership in Membership,
      where: ^dynamic_query,
      where: membership.account_id == ^account_id,
      join: policy in Policy,
      on:
        policy.actor_group_id == membership.group_id and
          policy.account_id == membership.account_id,
      where: is_nil(policy.deleted_at) and is_nil(policy.disabled_at),
      select: %{
        account_id: membership.account_id,
        actor_id: membership.actor_id,
        resource_id: policy.resource_id,
        inserted_at: fragment("TIMEZONE('UTC', NOW())")
      }
  end

  def delete_for_memberships(account_id, tuples) do
    dynamic_query =
      Enum.reduce(tuples, dynamic(true), fn {group_id, actor_id}, acc ->
        dynamic([m], (m.group_id == ^group_id and m.actor_id == ^actor_id) or ^acc)
      end)

    from membership in Membership,
      where: ^dynamic_query,
      where: membership.account_id == ^account_id,
      join: policy in Policy,
      on:
        policy.actor_group_id == membership.group_id and
          policy.account_id == membership.account_id
  end
end
