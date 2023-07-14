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

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end
end
