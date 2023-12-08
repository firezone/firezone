defmodule Domain.Relays.Group.Query do
  use Domain, :query

  def all do
    from(groups in Domain.Relays.Group, as: :groups)
  end

  def not_deleted do
    all()
    |> where([groups: groups], is_nil(groups.deleted_at))
  end

  def by_id(queryable \\ not_deleted(), id) do
    where(queryable, [groups: groups], groups.id == ^id)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [groups: groups], groups.account_id == ^account_id)
  end

  def global_or_by_account_id(queryable \\ not_deleted(), account_id) do
    where(
      queryable,
      [groups: groups],
      groups.account_id == ^account_id or is_nil(groups.account_id)
    )
  end
end
