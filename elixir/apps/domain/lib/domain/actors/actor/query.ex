defmodule Domain.Actors.Actor.Query do
  use Domain, :query

  def all do
    from(actors in Domain.Actors.Actor, as: :actors)
  end

  def not_deleted do
    all()
    |> where([actors: actors], is_nil(actors.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [actors: actors], is_nil(actors.disabled_at))
  end

  def by_id(queryable, {:in, ids}) do
    where(queryable, [actors: actors], actors.id in ^ids)
  end

  def by_id(queryable, {:not, id}) do
    where(queryable, [actors: actors], actors.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [actors: actors], actors.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [actors: actors], actors.account_id == ^account_id)
  end

  def by_type(queryable, type) do
    where(queryable, [actors: actors], actors.type == ^type)
  end

  # Preloads

  def preload_few_groups_for_each_actor(queryable, limit) do
    queryable
    |> with_joined_memberships(limit)
    |> with_joined_groups()
    |> with_joined_group_counts()
    |> select([actors: actors, groups: groups, group_counts: group_counts], %{
      id: actors.id,
      count: group_counts.count,
      item: groups
    })
  end

  def select_distinct_ids(queryable) do
    queryable
    |> select([actors: actors], actors.id)
    |> distinct(true)
  end

  def with_joined_memberships(queryable, limit) do
    subquery =
      Domain.Actors.Membership.Query.all()
      |> where([memberships: memberships], memberships.actor_id == parent_as(:actors).id)
      # we need second join to exclude soft deleted actors before applying a limit
      |> join(
        :inner,
        [memberships: memberships],
        groups in ^Domain.Actors.Group.Query.not_deleted(),
        on: groups.id == memberships.group_id
      )
      |> select([memberships: memberships], memberships.group_id)
      |> limit(^limit)

    join(queryable, :cross_lateral, [actors: actors], memberships in subquery(subquery),
      as: :memberships
    )
  end

  def with_joined_group_counts(queryable) do
    subquery =
      Domain.Actors.Membership.Query.count_groups_by_actor_id()
      |> where([memberships: memberships], memberships.actor_id == parent_as(:actors).id)

    join(queryable, :cross_lateral, [actors: actors], group_counts in subquery(subquery),
      as: :group_counts
    )
  end

  def with_joined_groups(queryable) do
    join(
      queryable,
      :left,
      [memberships: memberships],
      groups in ^Domain.Actors.Group.Query.not_deleted(),
      on: groups.id == memberships.group_id,
      as: :groups
    )
  end

  def with_joined_clients(queryable) do
    join(
      queryable,
      :left,
      [actors: actors],
      clients in ^Domain.Clients.Client.Query.not_deleted(),
      on: clients.actor_id == actors.id,
      as: :clients
    )
  end

  def with_joined_identities(queryable) do
    with_named_binding(queryable, :identities, fn queryable, binding ->
      join(
        queryable,
        :left,
        [actors: actors],
        identities in ^Domain.Auth.Identity.Query.not_deleted(),
        on: identities.actor_id == actors.id,
        as: ^binding
      )
    end)
  end

  def lock(queryable) do
    lock(queryable, "FOR UPDATE")
  end

  def with_assoc(queryable, qual \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, qual, [actors: actors], a in assoc(actors, ^binding), as: ^binding)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:actors, :asc, :inserted_at},
      {:actors, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads,
    do: [
      last_seen_at: &Domain.Actors.preload_last_seen_at/1
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :name_or_email,
        title: "Name or Email",
        type: {:string, :websearch},
        fun: &filter_by_name_or_email_fts/2
      },
      %Domain.Repo.Filter{
        name: :type,
        title: "Type",
        type: :string,
        values: [
          {"Account User", "account_user"},
          {"Account Admin User", "account_admin_user"},
          {"Service Account", "service_account"},
          {"API Client", "api_client"}
        ],
        fun: &filter_by_type/2
      },
      %Domain.Repo.Filter{
        name: :provider_id,
        title: "Provider",
        type: {:string, :uuid},
        values: [],
        fun: &filter_by_identity_provider_id/2
      }
    ]

  def filter_by_type(queryable, type) do
    type = String.to_existing_atom(type)
    {queryable, dynamic([actors: actors], actors.type == ^type)}
  end

  def filter_by_name_or_email_fts(queryable, name_or_email) do
    # EXISTS () is used here because otherwise we would need a join and will duplicate rows
    subquery =
      Domain.Auth.Identity.Query.all()
      |> where(
        [identities: identities],
        identities.actor_id == parent_as(:actors).id and
          (ilike(
             fragment("?->'userinfo'->>'email'", identities.provider_state),
             ^"%#{name_or_email}%"
           ) or ilike(identities.provider_identifier, ^"%#{name_or_email}%"))
      )

    {queryable,
     dynamic(
       [actors: actors],
       fulltext_search(actors.name, ^name_or_email) or
         exists(subquery)
     )}
  end

  def filter_by_identity_provider_id(queryable, provider_id) do
    subquery =
      Domain.Auth.Identity.Query.all()
      |> where(
        [identities: identities],
        identities.actor_id == parent_as(:actors).id and identities.provider_id == ^provider_id
      )

    {queryable, dynamic(exists(subquery))}
  end
end
