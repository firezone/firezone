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

  def by_group_id_and_actor_id(queryable \\ all(), {:in, tuples}) do
    queryable = where(queryable, [], false)

    Enum.reduce(tuples, queryable, fn {group_id, actor_id}, queryable ->
      or_where(
        queryable,
        [memberships: memberships],
        memberships.group_id == ^group_id and memberships.actor_id == ^actor_id
      )
    end)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [memberships: memberships], memberships.account_id == ^account_id)
  end

  def by_group_provider_id(queryable \\ all(), provider_id) do
    queryable
    |> with_assoc(:inner, :group)
    |> where([group: group], group.provider_id == ^provider_id)
  end

  def with_assoc(queryable \\ all(), type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [memberships: memberships], a in assoc(memberships, ^binding),
        as: ^binding
      )
    end)
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end
end
