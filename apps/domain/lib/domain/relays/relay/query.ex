defmodule Domain.Relays.Relay.Query do
  use Domain, :query

  def all do
    from(relays in Domain.Relays.Relay, as: :relays)
    |> where([relays: relays], is_nil(relays.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [relays: relays], relays.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [relays: relays], relays.user_id == ^user_id)
  end

  def returning_all(queryable \\ all()) do
    select(queryable, [relays: relays], relays)
  end

  def with_preloaded_user(queryable \\ all()) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      queryable
      |> join(:inner, [relays: relays], user in assoc(relays, ^binding), as: ^binding)
      |> preload([relays: relays, user: user], user: user)
    end)
  end
end
