defmodule Domain.Policies.Policy.Query do
  use Domain, :query

  def all do
    from(policies in Domain.Policies.Policy, as: :policies)
    |> where([policies: policies], is_nil(policies.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [policies: policies], policies.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [policies: policies], policies.account_id == ^account_id)
  end

  def by_resource_id(queryable \\ all(), resource_id) do
    where(queryable, [policies: policies], policies.resource_id == ^resource_id)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    queryable
    |> with_joined_memberships()
    |> where([memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def with_joined_actor_group(queryable \\ all()) do
    with_named_binding(queryable, :actor_group, fn queryable, binding ->
      join(queryable, :inner, [policies: policies], actor_group in assoc(policies, ^binding),
        as: ^binding
      )
    end)
  end

  def with_joined_memberships(queryable \\ all()) do
    queryable
    |> with_joined_actor_group()
    |> with_named_binding(:memberships, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [actor_group: actor_group],
        memberships in assoc(actor_group, ^binding),
        as: ^binding
      )
    end)
  end
end
