defmodule Domain.Auth.Provider.Query do
  use Domain, :query

  def all do
    from(provider in Domain.Auth.Provider, as: :provider)
    |> where([provider: provider], is_nil(provider.deleted_at))
  end

  def by_id(queryable \\ all(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [provider: provider], provider.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [provider: provider], provider.id == ^id)
  end

  def by_adapter(queryable \\ all(), adapter)

  def by_adapter(queryable, {:not_in, adapters}) do
    where(queryable, [provider: provider], provider.adapter not in ^adapters)
  end

  def by_adapter(queryable, adapter) do
    where(queryable, [provider: provider], provider.adapter == ^adapter)
  end

  def last_synced_at(queryable \\ all(), {:lt, datetime}) do
    where(
      queryable,
      [provider: provider],
      provider.last_synced_at < ^datetime or is_nil(provider.last_synced_at)
    )
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [provider: provider], provider.account_id == ^account_id)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [provider: provider], is_nil(provider.disabled_at))
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end
end
