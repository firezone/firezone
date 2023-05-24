defmodule Domain.Resources.Resource.Query do
  use Domain, :query

  def all do
    from(resources in Domain.Resources.Resource, as: :resources)
    |> where([resources: resources], is_nil(resources.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [resources: resources], resources.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [resources: resources], resources.account_id == ^account_id)
  end
end
