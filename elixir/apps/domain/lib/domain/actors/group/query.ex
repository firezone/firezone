defmodule Domain.Actors.Group.Query do
  use Domain, :query

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

  def not_synced_at(queryable, synced_at) do
    where(queryable, [groups: groups], groups.last_synced_at != ^synced_at)
  end

  # TODO: IDP REFACTOR
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
end
