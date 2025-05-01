defmodule Domain.Actors.Resource.Query do
  use Domain, :query
  alias Domain.Actors.{Actor, Membership, Resource}

  # Used for disable and soft-delete
  def by_policies(queryable) do
    from actor_resource in Resource,
      join: actor in Actor,
      on: actor_resource.actor_id == actor.id,
      join: membership in Membership,
      on: actor.id == membership.actor_id,
      join: policy in subquery(queryable),
      on:
        actor_resource.resource_id == policy.resource_id and
          membership.group_id == policy.actor_group_id and
          actor_resource.account_id == policy.account_id,
      select: actor_resource
  end

  # Used for enable and insert
  def insert_for_policies(queryable) do
    from policy in queryable,
      join: membership in Membership,
      on: policy.actor_group_id == membership.group_id,
      join: actor in Actor,
      on: membership.actor_id == actor.id,
      select: %{
        actor_id: actor.id,
        resource_id: policy.resource_id,
        account_id: policy.account_id,
        inserted_at: fragment("timezone(UTC, NOW())")
      }
  end
end
