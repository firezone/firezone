defmodule Domain.Actors.Membership.Query do
  use Domain, :query
  alias Domain.Actors.{Actor, Group, Membership}

  def all do
    from(memberships in Membership, as: :memberships)
  end

  def only_editable_groups(queryable \\ all()) do
    queryable
    |> with_joined_groups()
    |> where([groups: groups], is_nil(groups.provider_id) and groups.type == :static)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    where(queryable, [memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def by_group_id(queryable \\ all(), group_id)

  def by_group_id(queryable, {:in, group_ids}) do
    where(queryable, [memberships: memberships], memberships.group_id in ^group_ids)
  end

  def by_group_id(queryable, group_id) do
    where(queryable, [memberships: memberships], memberships.group_id == ^group_id)
  end

  def by_group_id_and_actor_id(queryable \\ all(), {:in, tuples}) do
    queryable = where(queryable, [], false)

    Enum.reduce(tuples, queryable, fn {group_id, actor_id}, queryable ->
      or_where(
        queryable,
        [memberships: memberships],
        memberships.group_id == ^group_id and memberships.actor_id == ^actor_id
      )
    end)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [memberships: memberships], memberships.account_id == ^account_id)
  end

  def by_group_provider_id(queryable \\ all(), provider_id) do
    queryable
    |> with_joined_groups()
    |> where([groups: groups], groups.provider_id == ^provider_id)
  end

  def count_actors_by_group_id(queryable \\ all()) do
    queryable
    |> group_by([memberships: memberships], memberships.group_id)
    |> with_joined_actors()
    |> select([memberships: memberships, actors: actors], %{
      group_id: memberships.group_id,
      count: count(actors.id)
    })
  end

  def count_groups_by_actor_id(queryable \\ all()) do
    queryable
    |> group_by([memberships: memberships], memberships.actor_id)
    |> with_joined_groups()
    |> select([memberships: memberships, groups: groups], %{
      actor_id: memberships.actor_id,
      count: count(groups.id)
    })
  end

  def select_distinct_group_ids(queryable \\ all()) do
    queryable
    |> select([memberships: memberships], memberships.group_id)
    |> distinct(true)
  end

  def returning_all(queryable \\ all()) do
    select(queryable, [memberships: memberships], memberships)
  end

  def with_joined_actors(queryable \\ all()) do
    join(queryable, :inner, [memberships: memberships], actors in ^Actor.Query.not_deleted(),
      on: actors.id == memberships.actor_id,
      as: :actors
    )
  end

  def with_joined_groups(queryable \\ all()) do
    join(
      queryable,
      :inner,
      [memberships: memberships],
      groups in ^Group.Query.not_deleted(),
      on: groups.id == memberships.group_id,
      as: :groups
    )
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:memberships, :asc, :inserted_at},
      {:memberships, :asc, :id}
    ]
end
