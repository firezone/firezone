defmodule Domain.Gateways.Group.Query do
  use Domain, :query

  def all do
    from(group in Domain.Gateways.Group, as: :group)
    |> where([group: group], is_nil(group.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [group: group], group.id == ^id)
  end
end
