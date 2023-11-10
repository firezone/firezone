defmodule Domain.Resources.Resource.Query do
  use Domain, :query

  def all do
    from(resources in Domain.Resources.Resource, as: :resources)
    |> where([resources: resources], is_nil(resources.deleted_at))
  end

  def by_id(queryable \\ all(), id)

  def by_id(queryable, {:in, ids}) do
    where(queryable, [resources: resources], resources.id in ^ids)
  end

  def by_id(queryable, id) do
    where(queryable, [resources: resources], resources.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [resources: resources], resources.account_id == ^account_id)
  end

  def by_authorized_actor_id(queryable \\ all(), actor_id) do
    subquery = Domain.Policies.Policy.Query.by_actor_id(actor_id)

    queryable
    |> join(
      :inner,
      [resources: resources],
      policies in subquery(subquery),
      on: policies.resource_id == resources.id,
      as: :authorized_by_policies
    )
    # Note: this will only write one of policies to a map, which means that
    # when a client has access to a resource using multiple policies (eg. being a member in multiple groups),
    # the policy used will be not deterministic
    |> select_merge([authorized_by_policies: policies], %{authorized_by_policy: policies})
  end

  def preload_few_actor_groups_for_each_resource(queryable \\ all(), limit) do
    queryable
    |> with_joined_actor_groups(limit)
    |> with_joined_policies_counts()
    |> select(
      [resources: resources, actor_groups: actor_groups, policies_counts: policies_counts],
      %{
        id: resources.id,
        count: policies_counts.count,
        item: actor_groups
      }
    )
  end

  def with_joined_actor_groups(queryable, limit) do
    policies_subquery =
      Domain.Policies.Policy.Query.all()
      |> where([policies: policies], policies.resource_id == parent_as(:resources).id)
      |> select([policies: policies], policies.actor_group_id)
      |> limit(^limit)

    actor_groups_subquery =
      Domain.Actors.Group.Query.all()
      |> where([groups: groups], groups.id in subquery(policies_subquery))

    join(
      queryable,
      :cross_lateral,
      [resources: resources],
      actor_groups in subquery(actor_groups_subquery),
      as: :actor_groups
    )
  end

  def with_joined_policies_counts(queryable) do
    subquery =
      Domain.Policies.Policy.Query.count_by_resource_id()
      |> where([policies: policies], policies.resource_id == parent_as(:resources).id)

    join(queryable, :cross_lateral, [resources: resources], policies_counts in subquery(subquery),
      as: :policies_counts
    )
  end

  def by_gateway_group_id(queryable \\ all(), gateway_group_id) do
    queryable
    |> with_joined_connections()
    |> where([connections: connections], connections.gateway_group_id == ^gateway_group_id)
  end

  def with_joined_connections(queryable \\ all()) do
    with_named_binding(queryable, :connections, fn queryable, binding ->
      queryable
      |> join(
        :inner,
        [resources: resources],
        connections in ^Domain.Resources.Connection.Query.all(),
        on: connections.resource_id == resources.id,
        as: ^binding
      )
    end)
  end
end
