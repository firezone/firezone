defmodule Domain.Auth.Identity.Query do
  use Domain, :query

  def all do
    from(identities in Domain.Auth.Identity, as: :identities)
    |> where([identities: identities], is_nil(identities.deleted_at))
    |> join(:inner, [identities: identities], actors in assoc(identities, :actor), as: :actors)
    |> where([actors: actors], is_nil(actors.deleted_at))
    |> where([actors: actors], is_nil(actors.disabled_at))
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

  def by_id_or_provider_identifier(queryable \\ all(), id_or_provider_identifier) do
    if Domain.Validator.valid_uuid?(id_or_provider_identifier) do
      where(
        queryable,
        [identities: identities],
        identities.provider_identifier == ^id_or_provider_identifier or
          identities.id == ^id_or_provider_identifier
      )
    else
      by_provider_identifier(queryable, id_or_provider_identifier)
    end
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end

  def with_preloaded_assoc(queryable \\ all(), type \\ :left, assoc) do
    queryable
    |> with_assoc(type, assoc)
    |> preload([{^assoc, assoc}], [{^assoc, assoc}])
  end

  def with_assoc(queryable \\ all(), type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [identities: identities], a in assoc(identities, ^binding), as: ^binding)
    end)
  end
end
