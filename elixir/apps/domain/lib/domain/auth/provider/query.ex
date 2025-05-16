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

  def assigned_default(queryable) do
    where(queryable, [providers: providers], not is_nil(providers.assigned_default_at))
  end

  def by_id(queryable, id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [providers: providers], providers.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [providers: providers], providers.id == ^id)
  end

  def by_adapter(queryable, adapter)

  def by_adapter(queryable, {:not_in, adapters}) do
    where(queryable, [providers: providers], providers.adapter not in ^adapters)
  end

  def by_adapter(queryable, adapter) do
    where(queryable, [providers: providers], providers.adapter == ^adapter)
  end

  def last_synced_at(queryable, {:lt, datetime}) do
    where(
      queryable,
      [providers: providers],
      providers.last_synced_at < ^datetime or is_nil(providers.last_synced_at)
    )
  end

  def only_ready_to_be_synced(queryable) do
    queryable
    |> where(
      [providers: providers],
      is_nil(providers.last_synced_at) or
        fragment(
          "? + LEAST((interval '10 minute' * (COALESCE(?, 0) ^ 2 + 1)), interval '4 hours') < timezone('UTC', NOW())",
          providers.last_synced_at,
          providers.last_syncs_failed
        )
    )
    |> where([providers: providers], is_nil(providers.sync_disabled_at))
  end

  def order_by_sync_priority(queryable) do
    order_by(queryable, [providers: providers], asc_nulls_first: providers.last_synced_at)
  end

  def by_non_empty_refresh_token(queryable) do
    where(
      queryable,
      [providers: providers],
      fragment("(?->>'refresh_token') IS NOT NULL", providers.adapter_state)
    )
  end

  def token_expires_at(queryable, {:lt, datetime}) do
    where(
      queryable,
      [providers: providers],
      fragment("(?->>'expires_at')::timestamp < ?", providers.adapter_state, ^datetime)
    )
  end

  def by_provisioner(queryable, provisioner) do
    where(queryable, [providers: providers], providers.provisioner == ^provisioner)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end

  def lock(queryable) do
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
