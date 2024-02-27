defmodule Domain.Auth.Provider.Query do
  use Domain, :query

  def all do
    from(provider in Domain.Auth.Provider, as: :providers)
  end

  def not_deleted do
    all()
    |> where([providers: providers], is_nil(providers.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [providers: providers], is_nil(providers.disabled_at))
  end

  def by_id(queryable \\ not_deleted(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [providers: providers], providers.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [providers: providers], providers.id == ^id)
  end

  def by_adapter(queryable \\ not_deleted(), adapter)

  def by_adapter(queryable, {:not_in, adapters}) do
    where(queryable, [providers: providers], providers.adapter not in ^adapters)
  end

  def by_adapter(queryable, adapter) do
    where(queryable, [providers: providers], providers.adapter == ^adapter)
  end

  def last_synced_at(queryable \\ not_deleted(), {:lt, datetime}) do
    where(
      queryable,
      [providers: providers],
      providers.last_synced_at < ^datetime or is_nil(providers.last_synced_at)
    )
  end

  def only_ready_to_be_synced(queryable \\ not_deleted()) do
    queryable
    |> where(
      [provider: provider],
      is_nil(provider.last_synced_at) or
        fragment(
          "? + LEAST((interval '10 minute' * (COALESCE(?, 0) ^ 2 + 1)), interval '4 hours') < NOW()",
          providers.last_synced_at,
          providers.last_syncs_failed
        )
    )
    |> where([provider: provider], is_nil(provider.sync_disabled_at))
  end

  def by_non_empty_refresh_token(queryable \\ not_deleted()) do
    where(
      queryable,
      [providers: providers],
      fragment("(?->>'refresh_token') IS NOT NULL", providers.adapter_state)
    )
  end

  def token_expires_at(queryable \\ not_deleted(), {:lt, datetime}) do
    where(
      queryable,
      [providers: providers],
      fragment("(?->>'expires_at')::timestamp < ?", providers.adapter_state, ^datetime)
    )
  end

  def by_provisioner(queryable \\ not_deleted(), provisioner) do
    where(queryable, [providers: providers], providers.provisioner == ^provisioner)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end

  def lock(queryable \\ not_deleted()) do
    lock(queryable, "FOR UPDATE")
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:providers, :asc, :inserted_at},
      {:providers, :asc, :id}
    ]
end
