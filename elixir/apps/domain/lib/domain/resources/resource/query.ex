defmodule Domain.Resources.Resource.Query do
  use Domain, :query

  def all do
    from(resources in Domain.Resources.Resource, as: :resources)
    |> where([resources: resources], is_nil(resources.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
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
    # when a client has access to multiple resources the policy used will be not deterministic
    |> select_merge([authorized_by_policies: policies], %{authorized_by_policy: policies})
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
