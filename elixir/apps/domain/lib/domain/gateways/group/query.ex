defmodule Domain.Gateways.Group.Query do
  use Domain, :query

  def all do
    from(groups in Domain.Gateways.Group, as: :groups)
  end

  def by_id(queryable, id) do
    where(queryable, [groups: groups], groups.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [groups: groups], groups.account_id == ^account_id)
  end

  def by_managed_by(queryable, managed_by) do
    where(queryable, [groups: groups], groups.managed_by == ^managed_by)
  end

  def by_name(queryable, name) do
    where(queryable, [groups: groups], groups.name == ^name)
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
      gateways: [
        online?: &Domain.Gateways.Presence.preload_gateways_presence/1
      ]
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :managed_by,
        type: :string,
        fun: &filter_managed_by/2
      }
    ]

  def filter_managed_by(queryable, managed_by) do
    {queryable, dynamic([groups: groups], groups.managed_by == ^managed_by)}
  end
end
