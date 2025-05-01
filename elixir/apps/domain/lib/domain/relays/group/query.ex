defmodule Domain.Relays.Group.Query do
  use Domain, :query

  def all do
    from(groups in Domain.Relays.Group, as: :groups)
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` is removed from the DB
  def not_deleted do
    all()
    |> where([groups: groups], is_nil(groups.deleted_at))
  end

  def by_id(queryable, id) do
    where(queryable, [groups: groups], groups.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [groups: groups], groups.account_id == ^account_id)
  end

  def global(queryable) do
    where(queryable, [groups: groups], is_nil(groups.account_id))
  end

  def global_or_by_account_id(queryable, account_id) do
    where(
      queryable,
      [groups: groups],
      groups.account_id == ^account_id or is_nil(groups.account_id)
    )
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:groups, :asc, :inserted_at},
      {:groups, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads,
    do: [
      relays: Domain.Relays.Relay.Query.preloads()
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :deleted?,
        type: :boolean,
        fun: &filter_deleted/1
      }
    ]

  # TODO: HARD-DELETE - Remove after `deleted_at` is removed from the DB
  def filter_deleted(queryable) do
    {queryable, dynamic([groups: groups], not is_nil(groups.deleted_at))}
  end
end
