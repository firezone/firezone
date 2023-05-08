defmodule Domain.Auth.Identity.Query do
  use Domain, :query
  import Domain.Auth, only: [has_permission?: 2]

  def all do
    from(identities in Domain.Auth.Identity, as: :identities)
    |> where([identities: identities], is_nil(identities.deleted_at))
  end

  def by_id(queryable \\ all(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [identities: identities], identities.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [identities: identities], identities.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [identities: identities], identities.account_id == ^account_id)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    where(queryable, [identities: identities], identities.actor_id == ^actor_id)
  end

  def by_provider_id(queryable \\ all(), provider_id) do
    queryable
    |> where([identities: identities], identities.provider_id == ^provider_id)
    |> with_assoc(:inner, :provider)
    |> where([provider: provider], is_nil(provider.disabled_at) and is_nil(provider.deleted_at))
  end

  def by_adapter(queryable \\ all(), adapter) do
    where(queryable, [identities: identities], identities.adapter == ^adapter)
  end

  def by_provider_identifier(queryable \\ all(), provider_identifier) do
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier == ^provider_identifier
    )
  end

  def with_assoc(queryable \\ all(), type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [identities: identities], a in assoc(identities, ^binding), as: ^binding)
    end)
  end
end
