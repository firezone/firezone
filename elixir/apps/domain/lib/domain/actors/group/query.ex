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

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:groups, :asc, :inserted_at},
      {:groups, :asc, :id}
    ]
end
