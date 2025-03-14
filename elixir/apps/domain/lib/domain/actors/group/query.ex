defmodule Domain.Actors.Group.Query do
  use Domain, :query

  def all do
    from(groups in Domain.Actors.Group, as: :groups)
  end

  def not_deleted do
    all()
    |> where([groups: groups], is_nil(groups.deleted_at))
  end

  def not_deleted_and_not_excluded do
    not_deleted()
    |> not_excluded()
  end

  def not_excluded(queryable \\ all()) do
    queryable
    |> join(:left, [groups: groups], providers in assoc(groups, :provider), as: :providers)
    |> where(
      [groups: groups, providers: providers],
      is_nil(groups.provider_id) or
        (not is_nil(groups.provider_id) and
           (is_nil(providers.group_filters_enabled_at) or not is_nil(groups.included_at)))
    )
  end

  def excluded(queryable) do
    queryable
    |> join(:inner, [groups: groups], providers in assoc(groups, :provider), as: :providers)
    |> where(
      [groups: groups, providers: providers],
      not is_nil(groups.provider_id) and
        (not is_nil(providers.group_filters_enabled_at) and is_nil(groups.included_at))
    )
  end

  def not_editable(queryable) do
    where(queryable, [groups: groups], not is_nil(groups.provider_id) or groups.type != :static)
  end

  def editable(queryable) do
    where(queryable, [groups: groups], is_nil(groups.provider_id) and groups.type == :static)
  end

  def by_id(queryable, id)

  def by_id(queryable, {:in, ids}) do
    where(queryable, [groups: groups], groups.id in ^ids)
  end

  def by_id(queryable, id) do
    where(queryable, [groups: groups], groups.id == ^id)
  end

  def by_type(queryable, type)

  def by_type(queryable, {:in, types}) do
    where(queryable, [groups: groups], groups.type in ^types)
  end

  def by_type(queryable, type) do
    where(queryable, [groups: groups], groups.type == ^type)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [groups: groups], groups.account_id == ^account_id)
  end

  def by_actor_id(queryable, actor_id) do
    join(queryable, :left, [groups: groups], memberships in assoc(groups, :memberships),
      as: :memberships
    )
    |> where([memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def by_provider_id(queryable, provider_id) do
    where(queryable, [groups: groups], groups.provider_id == ^provider_id)
  end

  def by_provider_identifier(queryable, provider_identifier)

  def by_provider_identifier(queryable, {:in, provider_identifiers}) do
    where(queryable, [groups: groups], groups.provider_identifier in ^provider_identifiers)
  end

  def by_provider_identifier(queryable, provider_identifier) do
    where(queryable, [groups: groups], groups.provider_identifier == ^provider_identifier)
  end

  def delete(queryable) do
    queryable
    |> Ecto.Query.select([groups: groups], groups)
    |> Ecto.Query.update([groups: groups],
      set: [
        deleted_at: fragment("COALESCE(?, timezone('UTC', NOW()))", groups.deleted_at)
      ]
    )
  end

  def set_excluded(queryable, group_ids) do
    queryable
    |> where([groups: groups], groups.id in ^group_ids)
    |> update([groups: groups],
      set: [
        included_at: nil
      ]
    )
  end

  def set_included(queryable, group_ids) do
    queryable
    |> where([groups: groups], groups.id in ^group_ids)
    |> update([groups: groups],
      set: [
        included_at: fragment("COALESCE(?, timezone('UTC', NOW()))", groups.included_at)
      ]
    )
  end

  def excluded_ids(provider) do
    not_deleted()
    |> excluded()
    |> by_provider_id(provider.id)
    |> select([groups: groups], groups.id)
  end

  def group_by_provider_id(queryable) do
    queryable
    |> group_by([groups: groups], groups.provider_id)
    |> where([groups: groups], not is_nil(groups.provider_id))
    |> select([groups: groups], %{
      provider_id: groups.provider_id,
      count: count(groups.id)
    })
  end

  def preload_few_actors_for_each_group(queryable, limit) do
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

  def with_joined_actors(queryable) do
    join(
      queryable,
      :left,
      [memberships: memberships],
      actors in ^Domain.Actors.Actor.Query.not_deleted(),
      on: actors.id == memberships.actor_id,
      as: :actors
    )
  end

  def lock(queryable) do
    lock(queryable, "FOR UPDATE")
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:groups, :asc, :inserted_at},
      {:groups, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :name,
        title: "Name",
        type: {:string, :websearch},
        fun: &filter_by_name_fts/2
      },
      %Domain.Repo.Filter{
        name: :provider_id,
        title: "Provider",
        type: {:string, :uuid},
        values: &Domain.Auth.all_third_party_providers!/1,
        fun: &filter_by_provider_id/2
      },
      %Domain.Repo.Filter{
        name: :deleted?,
        type: :boolean,
        fun: &filter_deleted/1
      },
      %Domain.Repo.Filter{
        name: :editable?,
        type: :boolean,
        fun: &filter_editable/1
      }
    ]

  def filter_by_name_fts(queryable, name) do
    {queryable, dynamic([groups: groups], fulltext_search(groups.name, ^name))}
  end

  def filter_by_provider_id(queryable, provider_id) do
    {queryable, dynamic([groups: groups], groups.provider_id == ^provider_id)}
  end

  def filter_deleted(queryable) do
    {queryable, dynamic([groups: groups], not is_nil(groups.deleted_at))}
  end

  def filter_editable(queryable) do
    {queryable,
     dynamic(
       [groups: groups],
       is_nil(groups.provider_id) and
         is_nil(groups.deleted_at) and
         groups.type == :static
     )}
  end
end
