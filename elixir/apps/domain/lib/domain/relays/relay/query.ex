defmodule Domain.Relays.Relay.Query do
  use Domain, :query

  def all do
    from(relays in Domain.Relays.Relay, as: :relays)
  end

  def by_id(queryable, id) do
    where(queryable, [relays: relays], relays.id == ^id)
  end

  def by_ids(queryable, ids) do
    where(queryable, [relays: relays], relays.id in ^ids)
  end

  def by_group_id(queryable, group_id) do
    where(queryable, [relays: relays], relays.group_id == ^group_id)
  end

  def by_user_id(queryable, user_id) do
    where(queryable, [relays: relays], relays.user_id == ^user_id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [relays: relays], relays.account_id == ^account_id)
  end

  def by_last_seen_at_greater_than(queryable, value, unit, :ago) do
    where(queryable, [relays: relays], relays.last_seen_at < ago(^value, ^unit))
  end

  def public(queryable) do
    where(
      queryable,
      [relays: relays],
      is_nil(relays.account_id)
    )
  end

  def global_or_by_account_id(queryable, account_id) do
    where(
      queryable,
      [relays: relays],
      relays.account_id == ^account_id or is_nil(relays.account_id)
    )
  end

  def prefer_global(queryable) do
    order_by(queryable, [relays: relays], asc_nulls_first: relays.account_id)
  end

  def with_preloaded_user(queryable) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      queryable
      |> join(:inner, [relays: relays], user in assoc(relays, ^binding), as: ^binding)
      |> preload([relays: relays, user: user], user: user)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:relays, :asc, :inserted_at},
      {:relays, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads,
    do: [
      online?: &Domain.Presence.Relays.preload_relays_presence/1
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :relay_group_id,
        type: {:string, :uuid},
        values: [],
        fun: &filter_by_group_id/2
      },
      %Domain.Repo.Filter{
        name: :ids,
        type: {:list, {:string, :uuid}},
        fun: &filter_by_ids/2
      }
    ]

  def filter_by_group_id(queryable, group_id) do
    {queryable, dynamic([relays: relays], relays.group_id == ^group_id)}
  end

  def filter_by_ids(queryable, ids) do
    {queryable, dynamic([relays: relays], relays.id in ^ids)}
  end
end
