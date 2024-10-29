defmodule Domain.Resources.Resource.Query do
  use Domain, :query

  def all do
    from(resources in Domain.Resources.Resource, as: :resources)
  end

  def not_deleted do
    all()
    |> where([resources: resources], is_nil(resources.deleted_at))
  end

  def filter_features(queryable, %Domain.Accounts.Account{} = account) do
    if Domain.Accounts.internet_resource_enabled?(account) do
      queryable
    else
      where(queryable, [resources: resources], resources.type != ^:internet)
    end
  end

  def by_id(queryable, {:in, ids}) do
    where(queryable, [resources: resources], resources.id in ^ids)
  end

  def by_id(queryable, id) do
    where(queryable, [resources: resources], resources.id == ^id)
  end

  def by_id_or_persistent_id(queryable, id) do
    where(queryable, [resources: resources], resources.id == ^id)
    |> or_where(
      [resources: resources],
      resources.persistent_id == ^id and is_nil(resources.replaced_by_resource_id)
    )
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [resources: resources], resources.account_id == ^account_id)
  end

  def by_authorized_actor_id(queryable, actor_id) do
    queryable
    |> join(
      :inner,
      [resources: resources],
      policies in ^Domain.Policies.Policy.Query.not_disabled(),
      on: policies.resource_id == resources.id,
      as: :policies
    )
    |> Domain.Policies.Policy.Query.by_actor_id(actor_id)
    |> preload([resources: resources, policies: policies],
      authorized_by_policies: policies
    )
  end

  def with_at_least_one_gateway_group(queryable) do
    queryable
    |> with_joined_connection_gateway_group()
  end

  def preload_few_actor_groups_for_each_resource(queryable, limit) do
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
      Domain.Policies.Policy.Query.not_disabled()
      |> where([policies: policies], policies.resource_id == parent_as(:resources).id)
      |> select([policies: policies], policies.actor_group_id)
      |> limit(^limit)

    actor_groups_subquery =
      Domain.Actors.Group.Query.not_deleted()
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
      Domain.Policies.Policy.Query.not_disabled()
      |> Domain.Policies.Policy.Query.count_by_resource_id()
      |> where([policies: policies], policies.resource_id == parent_as(:resources).id)

    join(queryable, :cross_lateral, [resources: resources], policies_counts in subquery(subquery),
      as: :policies_counts
    )
  end

  def by_gateway_group_id(queryable, gateway_group_id) do
    queryable
    |> with_joined_connections()
    |> where([connections: connections], connections.gateway_group_id == ^gateway_group_id)
  end

  def with_joined_connections(queryable) do
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

  def with_joined_connection_gateway_group(queryable) do
    queryable
    |> with_joined_connections()
    |> with_named_binding(:gateway_group, fn queryable, binding ->
      queryable
      |> join(
        :inner,
        [connections: connections],
        gateway_group in ^Domain.Gateways.Group.Query.not_deleted(),
        on: gateway_group.id == connections.gateway_group_id,
        as: ^binding
      )
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:resources, :asc, :inserted_at},
      {:resources, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :name_or_address,
        title: "Name or Address",
        type: {:string, :websearch},
        fun: &filter_by_name_fts_or_address/2
      },
      %Domain.Repo.Filter{
        name: :gateway_group_id,
        type: {:string, :uuid},
        values: [],
        fun: &filter_by_gateway_group_id/2
      },
      %Domain.Repo.Filter{
        name: :deleted?,
        type: :boolean,
        fun: &filter_deleted/1
      }
    ]

  def filter_by_name_fts_or_address(queryable, name_or_address) do
    {queryable,
     dynamic(
       [resources: resources],
       fulltext_search(resources.name, ^name_or_address) or
         ilike(resources.address, ^"%#{name_or_address}%")
     )}
  end

  def filter_by_gateway_group_id(queryable, gateway_group_id) do
    {with_joined_connections(queryable),
     dynamic([connections: connections], connections.gateway_group_id == ^gateway_group_id)}
  end

  def filter_deleted(queryable) do
    {queryable, dynamic([resources: resources], not is_nil(resources.deleted_at))}
  end
end
