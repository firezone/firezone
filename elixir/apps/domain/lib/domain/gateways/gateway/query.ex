defmodule Domain.Gateways.Gateway.Query do
  use Domain, :query

  def all do
    from(gateways in Domain.Gateways.Gateway, as: :gateways)
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def not_deleted do
    all()
    |> where([gateways: gateways], is_nil(gateways.deleted_at))
  end

  def by_id(queryable, id) do
    where(queryable, [gateways: gateways], gateways.id == ^id)
  end

  def by_ids(queryable, ids) do
    where(queryable, [gateways: gateways], gateways.id in ^ids)
  end

  def by_user_id(queryable, user_id) do
    where(queryable, [gateways: gateways], gateways.user_id == ^user_id)
  end

  def by_group_id(queryable, group_id) do
    where(queryable, [gateways: gateways], gateways.group_id == ^group_id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [gateways: gateways], gateways.account_id == ^account_id)
  end

  def by_resource_id(queryable, resource_id) do
    queryable
    |> with_joined_connections()
    |> where([connections: connections], connections.resource_id == ^resource_id)
  end

  def returning_not_deleted(queryable) do
    select(queryable, [gateways: gateways], gateways)
  end

  def with_joined_connections(queryable) do
    with_named_binding(queryable, :connections, fn queryable, binding ->
      queryable
      |> join(
        :inner,
        [gateways: gateways],
        connections in ^Domain.Resources.Connection.Query.all(),
        on: connections.gateway_group_id == gateways.group_id,
        as: ^binding
      )
    end)
  end

  def with_preloaded_user(queryable) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      queryable
      |> join(:inner, [gateways: gateways], user in assoc(gateways, ^binding), as: ^binding)
      |> preload([gateways: gateways, user: user], user: user)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:gateways, :asc, :last_seen_at},
      {:gateways, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads do
    [
      online?: &Domain.Gateways.preload_gateways_presence/1
    ]
  end

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :gateway_group_id,
        title: "Site",
        type: {:string, :uuid},
        values: [],
        fun: &filter_by_group_id/2
      },
      %Domain.Repo.Filter{
        name: :ids,
        type: {:list, {:string, :uuid}},
        fun: &filter_by_ids/2
      },
      %Domain.Repo.Filter{
        name: :deleted?,
        type: :boolean,
        fun: &filter_deleted/1
      }
    ]

  def filter_by_group_id(queryable, group_id) do
    {queryable, dynamic([gateways: gateways], gateways.group_id == ^group_id)}
  end

  def filter_by_ids(queryable, ids) do
    {queryable, dynamic([gateways: gateways], gateways.id in ^ids)}
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def filter_deleted(queryable) do
    {queryable, dynamic([gateways: gateways], not is_nil(gateways.deleted_at))}
  end
end
