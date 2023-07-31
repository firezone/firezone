defmodule Domain.Actors.Membership.Query do
  use Domain, :query

  def all do
    from(memberships in Domain.Actors.Membership, as: :memberships)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    where(queryable, [memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def by_group_id(queryable \\ all(), group_id) do
    where(queryable, [memberships: memberships], memberships.group_id == ^group_id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [memberships: memberships], memberships.account_id == ^account_id)
  end
end
