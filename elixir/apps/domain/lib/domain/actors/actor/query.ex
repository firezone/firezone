defmodule Domain.Actors.Actor.Query do
  use Domain, :query

  def all do
    from(actors in Domain.Actors.Actor, as: :actors)
  end

  def not_disabled(queryable \\ all()) do
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

  def by_email(queryable, email) do
    where(queryable, [actors: actors], actors.email == ^email)
  end

  def by_identity_provider_id(queryable, provider_id) do
    queryable
    |> join(:inner, [actors: actors], identities in ^Domain.Auth.Identity.Query.all(),
      on: identities.actor_id == actors.id and identities.account_id == actors.account_id,
      as: :identities
    )
    |> where(
      [identities: identities],
      identities.provider_id == ^provider_id
    )
  end

  def by_type(queryable, {:in, types}) do
    where(queryable, [actors: actors], actors.type in ^types)
  end

  def by_type(queryable, type) do
    where(queryable, [actors: actors], actors.type == ^type)
  end

  # Preloads

  def preload_few_clients_for_each_actor(queryable, limit) do
    queryable
    |> with_joined_clients(limit)
    |> with_joined_client_counts()
    |> select([actors: actors, clients: clients, client_counts: client_counts], %{
      id: actors.id,
      count: client_counts.count,
      item: clients
    })
  end

  def with_joined_clients(queryable, limit) do
    subquery =
      Domain.Clients.Client.Query.all()
      |> where([clients: clients], clients.actor_id == parent_as(:actors).id)
      |> order_by([clients: clients], desc: clients.last_seen_at)
      |> limit(^limit)

    join(queryable, :cross_lateral, [actors: actors], clients in subquery(subquery), as: :clients)
  end

  def with_joined_client_counts(queryable) do
    subquery =
      Domain.Clients.Client.Query.count_clients_by_actor_id()
      |> where([clients: clients], clients.actor_id == parent_as(:actors).id)

    join(queryable, :cross_lateral, [actors: actors], client_counts in subquery(subquery),
      as: :client_counts
    )
  end

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
      groups in ^Domain.Actors.Group.Query.all(),
      on: groups.id == memberships.group_id,
      as: :groups
    )
  end

  def with_joined_clients(queryable) do
    join(
      queryable,
      :left,
      [actors: actors],
      clients in ^Domain.Clients.Client.Query.all(),
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
        identities in ^Domain.Auth.Identity.Query.all(),
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
end
