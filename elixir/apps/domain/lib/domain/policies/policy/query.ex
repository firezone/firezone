defmodule Domain.Policies.Policy.Query do
  use Domain, :query

  def all do
    from(policies in Domain.Policies.Policy, as: :policies)
  end

  def not_deleted do
    all()
    |> where([policies: policies], is_nil(policies.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [policies: policies], is_nil(policies.disabled_at))
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

  def by_actor_group_id(queryable \\ not_deleted(), actor_group_id) do
    queryable
    |> where([policies: policies], policies.actor_group_id == ^actor_group_id)
  end

  def by_actor_group_provider_id(queryable \\ not_deleted(), provider_id) do
    queryable
    |> with_joined_actor_group()
    |> where([actor_group: actor_group], actor_group.provider_id == ^provider_id)
  end

  def by_actor_id(queryable \\ not_deleted(), actor_id) do
    queryable
    |> with_joined_memberships()
    |> where([memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def count_by_resource_id(queryable \\ not_disabled()) do
    queryable
    |> group_by([policies: policies], policies.resource_id)
    |> select([policies: policies], %{
      resource_id: policies.resource_id,
      count: count(policies.id)
    })
  end

  def delete(queryable \\ not_deleted()) do
    queryable
    |> Ecto.Query.select([policies: policies], policies)
    |> Ecto.Query.update([policies: policies],
      set: [
        deleted_at: fragment("COALESCE(?, NOW())", policies.deleted_at)
      ]
    )
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
