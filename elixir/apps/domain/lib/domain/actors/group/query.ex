defmodule Domain.Actors.Group.Query do
  use Domain, :query

  def all do
    from(groups in Domain.Actors.Group, as: :groups)
    |> where([groups: groups], is_nil(groups.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [groups: groups], groups.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [groups: groups], groups.account_id == ^account_id)
  end

  def by_provider_id(queryable \\ all(), provider_id) do
    where(queryable, [groups: groups], groups.provider_id == ^provider_id)
  end

  def by_provider_identifier(queryable \\ all(), provider_identifier) do
    where(queryable, [groups: groups], groups.provider_identifier == ^provider_identifier)
  end

  def group_by_provider_id(queryable \\ all()) do
    queryable
    |> group_by([groups: groups], groups.provider_id)
    |> where([groups: groups], not is_nil(groups.provider_id))
    |> select([groups: groups], %{
      provider_id: groups.provider_id,
      count: count(groups.id)
    })
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end
end
