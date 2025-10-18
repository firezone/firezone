defmodule Domain.Actors.Group.Query do
  use Domain, :query
  alias Domain.{Actors, Repo}

  def all do
    from(groups in Domain.Actors.Group, as: :groups)
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

  def not_synced_at(queryable, synced_at) do
    where(queryable, [groups: groups], groups.last_synced_at != ^synced_at)
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
      actors in ^Domain.Actors.Actor.Query.all(),
      on: actors.id == memberships.actor_id,
      as: :actors
    )
  end

  def batch_upsert(_account_id, _provider_id, _now, []), do: {:ok, %{upserted_groups: 0}}

  def batch_upsert(account_id, provider_id, now, group_attrs) do
    values =
      Enum.map(group_attrs, fn attrs ->
        %{
          id: Ecto.UUID.generate(),
          name: attrs.name,
          provider_id: provider_id,
          provider_identifier: attrs.provider_identifier,
          account_id: account_id,
          inserted_at: now,
          updated_at: now,
          created_by: :provider,
          type: :static,
          created_by_subject: %{"name" => "Provider", "email" => nil},
          last_synced_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(Actors.Group, values,
        on_conflict: {:replace, [:name, :last_synced_at, :updated_at]},
        conflict_target:
          {:unsafe_fragment,
           ~s/(account_id, provider_id, provider_identifier) WHERE provider_id IS NOT NULL and provider_identifier IS NOT NULL/},
        returning: false
      )

    {:ok, %{upserted_groups: count}}
  end

  # TODO: IDP Sync
  # See: https://github.com/firezone/firezone/issues/8750
  # We use CTE here which should be very performant even for very large inserts
  def update_everyone_group_memberships(account_id) do
    # Insert memberships for the cross join of user actors and managed groups
    insert_with_cte_fn = fn repo, _changes ->
      current_memberships_cte =
        from(
          a in Domain.Actors.Actor,
          cross_join: g in Domain.Actors.Group,
          where:
            a.account_id == ^account_id and
              a.type in [:account_user, :account_admin_user] and
              g.type == :managed and
              g.account_id == ^account_id,
          select: %{
            actor_id: a.id,
            group_id: g.id
          }
        )

      insert_query =
        from(
          cm in "current_memberships",
          select: %{
            actor_id: cm.actor_id,
            group_id: cm.group_id,
            account_id: type(^account_id, :binary_id)
          }
        )
        |> with_cte("current_memberships", as: ^current_memberships_cte)

      case repo.insert_all(Domain.Actors.Membership, insert_query,
             on_conflict: :nothing,
             conflict_target: [:actor_id, :group_id]
           ) do
        {count, _} -> {:ok, count}
        error -> {:error, error}
      end
    end

    Ecto.Multi.new()
    |> Ecto.Multi.run(:insert_memberships, insert_with_cte_fn)
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

  def filter_editable(queryable) do
    {queryable,
     dynamic(
       [groups: groups],
       is_nil(groups.provider_id) and groups.type == :static
     )}
  end
end
