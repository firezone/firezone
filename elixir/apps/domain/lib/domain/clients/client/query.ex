defmodule Domain.Clients.Client.Query do
  use Domain, :query

  def all do
    from(clients in Domain.Clients.Client, as: :clients)
  end

  def not_deleted do
    all()
    |> where([clients: clients], is_nil(clients.deleted_at))
  end

  def by_id(queryable \\ not_deleted(), id) do
    where(queryable, [clients: clients], clients.id == ^id)
  end

  def by_actor_id(queryable \\ not_deleted(), actor_id) do
    where(queryable, [clients: clients], clients.actor_id == ^actor_id)
  end

  def only_for_active_actors(queryable \\ not_deleted()) do
    queryable
    |> with_joined_actor()
    |> where([actor: actor], is_nil(actor.disabled_at))
  end

  def by_actor_type(queryable \\ not_deleted(), {:in, types}) do
    queryable
    |> with_joined_actor()
    |> where([actor: actor], actor.type in ^types)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [clients: clients], clients.account_id == ^account_id)
  end

  def by_last_used_token_id(queryable \\ not_deleted(), last_used_token_id) do
    where(queryable, [clients: clients], clients.last_used_token_id == ^last_used_token_id)
  end

  def by_last_seen_within(queryable \\ not_deleted(), period, unit) do
    where(queryable, [clients: clients], clients.last_seen_at > ago(^period, ^unit))
  end

  def select_distinct_actor_id(queryable \\ not_deleted()) do
    queryable
    |> select([clients: clients], clients.actor_id)
    |> distinct(true)
  end

  def returning_not_deleted(queryable \\ not_deleted()) do
    select(queryable, [clients: clients], clients)
  end

  def delete(queryable \\ not_deleted()) do
    queryable
    |> Ecto.Query.select([clients: clients], clients)
    |> Ecto.Query.update([clients: clients],
      set: [
        deleted_at: fragment("COALESCE(?, NOW())", clients.deleted_at)
      ]
    )
  end

  def with_joined_actor(queryable \\ not_deleted()) do
    with_named_binding(queryable, :actor, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [clients: clients],
        actor in ^Domain.Actors.Actor.Query.not_deleted(),
        on: clients.actor_id == actor.id,
        as: ^binding
      )
    end)
  end

  def with_preloaded_actor(queryable \\ not_deleted()) do
    queryable
    |> with_joined_actor()
    |> preload([clients: clients, actor: actor], actor: actor)
  end

  def with_preloaded_identity(queryable \\ not_deleted()) do
    with_named_binding(queryable, :identity, fn queryable, binding ->
      queryable
      |> join(:inner, [clients: clients], identity in assoc(clients, ^binding), as: ^binding)
      |> preload([clients: clients, identity: identity], identity: identity)
    end)
  end
end
