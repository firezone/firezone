defmodule Domain.Auth.Provider.Query do
  use Domain, :query

  def all do
    from(provider in Domain.Auth.Provider, as: :provider)
  end

  def not_deleted do
    all()
    |> where([provider: provider], is_nil(provider.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [provider: provider], is_nil(provider.disabled_at))
  end

  def not_exceeded_attempts(queryable \\ not_deleted()) do
    where(queryable, [provider: provider], provider.last_syncs_failed <= 10)
  end

  def by_id(queryable \\ not_deleted(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [provider: provider], provider.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [provider: provider], provider.id == ^id)
  end

  def by_adapter(queryable \\ not_deleted(), adapter)

  def by_adapter(queryable, {:not_in, adapters}) do
    where(queryable, [provider: provider], provider.adapter not in ^adapters)
  end

  def by_adapter(queryable, adapter) do
    where(queryable, [provider: provider], provider.adapter == ^adapter)
  end

  def last_synced_at(queryable \\ not_deleted(), {:lt, datetime}) do
    where(
      queryable,
      [provider: provider],
      provider.last_synced_at < ^datetime or is_nil(provider.last_synced_at)
    )
  end

  def only_ready_to_be_synced(queryable \\ not_deleted()) do
    where(
      queryable,
      [provider: provider],
      is_nil(provider.last_synced_at) or
        fragment(
          "? + LEAST((interval '10 minute' * (COALESCE(?, 0) ^ 2 + 1)), interval '4 hours') < NOW()",
          provider.last_synced_at,
          provider.last_syncs_failed
        )
    )
  end

  def by_non_empty_refresh_token(queryable \\ not_deleted()) do
    where(
      queryable,
      [provider: provider],
      fragment("(?->>'refresh_token') IS NOT NULL", provider.adapter_state)
    )
  end

  def token_expires_at(queryable \\ not_deleted(), {:lt, datetime}) do
    where(
      queryable,
      [provider: provider],
      fragment("(?->>'expires_at')::timestamp < ?", provider.adapter_state, ^datetime)
    )
  end

  def by_provisioner(queryable \\ not_deleted(), provisioner) do
    where(queryable, [provider: provider], provider.provisioner == ^provisioner)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [provider: provider], provider.account_id == ^account_id)
  end

  def lock(queryable \\ not_deleted()) do
    lock(queryable, "FOR UPDATE")
  end
end
