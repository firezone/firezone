defmodule Domain.Actors.Group.Query do
  use Domain, :query

  def all do
    from(groups in Domain.Actors.Group, as: :groups)
  end

  def not_deleted do
    all()
    |> where([groups: groups], is_nil(groups.deleted_at))
  end

  def not_editable(queryable \\ not_deleted()) do
    where(queryable, [groups: groups], not is_nil(groups.provider_id) or groups.type != :static)
  end

  def editable(queryable \\ not_deleted()) do
    where(queryable, [groups: groups], is_nil(groups.provider_id) and groups.type == :static)
  end

  def by_id(queryable \\ not_deleted(), id)

  def by_id(queryable, {:in, ids}) do
    where(queryable, [groups: groups], groups.id in ^ids)
  end

  def by_id(queryable, id) do
    where(queryable, [groups: groups], groups.id == ^id)
  end

  def by_type(queryable \\ not_deleted(), type)

  def by_type(queryable, {:in, types}) do
    where(queryable, [groups: groups], groups.type in ^types)
  end

  def by_type(queryable, type) do
    where(queryable, [groups: groups], groups.type == ^type)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [groups: groups], groups.account_id == ^account_id)
  end

  def by_provider_id(queryable \\ not_deleted(), provider_id) do
    where(queryable, [groups: groups], groups.provider_id == ^provider_id)
  end

  def by_provider_identifier(queryable \\ not_deleted(), provider_identifier)

  def by_provider_identifier(queryable, {:in, provider_identifiers}) do
    where(queryable, [groups: groups], groups.provider_identifier in ^provider_identifiers)
  end

  def by_provider_identifier(queryable, provider_identifier) do
    where(queryable, [groups: groups], groups.provider_identifier == ^provider_identifier)
  end

  def delete(queryable \\ not_deleted()) do
    queryable
    |> Ecto.Query.select([groups: groups], groups)
    |> Ecto.Query.update([groups: groups],
      set: [
        deleted_at: fragment("COALESCE(?, NOW())", groups.deleted_at)
      ]
    )
  end

  def group_by_provider_id(queryable \\ not_deleted()) do
    queryable
    |> group_by([groups: groups], groups.provider_id)
    |> where([groups: groups], not is_nil(groups.provider_id))
    |> select([groups: groups], %{
      provider_id: groups.provider_id,
      count: count(groups.id)
    })
  end

  def preload_few_actors_for_each_group(queryable \\ not_deleted(), limit) do
    queryable
    |> with_joined_memberships(limit)
    |> with_joined_actors()
    |> with_joined_actor_counts()
    |> select([groups: groups, actors: actors, actor_counts: actor_counts], %{
      id: groups.id,
      count: actor_counts.count,
      item: actors
    })
  end

  def with_joined_memberships(queryable) do
    join(queryable, :left, [groups: groups], memberships in assoc(groups, :memberships),
      as: :memberships
    )
  end

  def with_joined_memberships(queryable, limit) do
    subquery =
      Domain.Actors.Membership.Query.all()
      |> where([memberships: memberships], memberships.group_id == parent_as(:groups).id)
      # we need second join to exclude soft deleted actors before applying a limit
      |> join(
        :inner,
        [memberships: memberships],
        actors in ^Domain.Actors.Actor.Query.not_deleted(),
        on: actors.id == memberships.actor_id
      )
      |> select([memberships: memberships], memberships.actor_id)
      |> limit(^limit)

    join(queryable, :cross_lateral, [groups: groups], memberships in subquery(subquery),
      as: :memberships
    )
  end

  def with_joined_actor_counts(queryable) do
    subquery =
      Domain.Actors.Membership.Query.count_actors_by_group_id()
      |> where([memberships: memberships], memberships.group_id == parent_as(:groups).id)

    join(queryable, :cross_lateral, [groups: groups], actor_counts in subquery(subquery),
      as: :actor_counts
    )
  end

  def with_joined_actors(queryable \\ not_deleted()) do
    join(
      queryable,
      :left,
      [memberships: memberships],
      actors in ^Domain.Actors.Actor.Query.not_deleted(),
      on: actors.id == memberships.actor_id,
      as: :actors
    )
  end

  def lock(queryable \\ not_deleted()) do
    lock(queryable, "FOR NO KEY UPDATE")
  end
end
