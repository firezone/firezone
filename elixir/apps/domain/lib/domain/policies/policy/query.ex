defmodule Domain.Policies.Policy.Query do
  use Domain, :query

  def all do
    from(policies in Domain.Policies.Policy, as: :policies)
  end

  def not_deleted do
    from(policies in Domain.Policies.Policy, as: :policies)
    |> where([policies: policies], is_nil(policies.deleted_at))
    |> with_joined_actor_group()
    |> where([actor_group: actor_group], is_nil(actor_group.deleted_at))
    |> with_joined_resource()
    |> where([resource: resource], is_nil(resource.deleted_at))
  end

  def by_id(queryable \\ not_deleted(), id) do
    where(queryable, [policies: policies], policies.id == ^id)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [policies: policies], policies.account_id == ^account_id)
  end

  def by_resource_id(queryable \\ not_deleted(), resource_id) do
    where(queryable, [policies: policies], policies.resource_id == ^resource_id)
  end

  def by_resource_ids(queryable \\ not_deleted(), resource_ids) do
    where(queryable, [policies: policies], policies.resource_id in ^resource_ids)
  end

  def by_actor_id(queryable \\ not_deleted(), actor_id) do
    queryable
    |> with_joined_memberships()
    |> where([memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def count_by_resource_id(queryable \\ not_deleted()) do
    queryable
    |> group_by([policies: policies], policies.resource_id)
    |> select([policies: policies], %{
      resource_id: policies.resource_id,
      count: count(policies.id)
    })
  end

  def with_joined_actor_group(queryable \\ not_deleted()) do
    with_named_binding(queryable, :actor_group, fn queryable, binding ->
      join(queryable, :inner, [policies: policies], actor_group in assoc(policies, ^binding),
        as: ^binding
      )
    end)
  end

  def with_joined_resource(queryable \\ not_deleted()) do
    with_named_binding(queryable, :resource, fn queryable, binding ->
      join(queryable, :inner, [policies: policies], resource in assoc(policies, ^binding),
        as: ^binding
      )
    end)
  end

  def with_joined_memberships(queryable \\ not_deleted()) do
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
