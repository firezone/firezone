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

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [clients: clients], clients.account_id == ^account_id)
  end

  def returning_not_deleted(queryable \\ not_deleted()) do
    select(queryable, [clients: clients], clients)
  end

  def with_preloaded_actor(queryable \\ not_deleted()) do
    with_named_binding(queryable, :actor, fn queryable, binding ->
      queryable
      |> join(:inner, [clients: clients], actor in assoc(clients, ^binding), as: ^binding)
      |> preload([clients: clients, actor: actor], actor: actor)
    end)
  end

  def with_preloaded_identity(queryable \\ not_deleted()) do
    with_named_binding(queryable, :identity, fn queryable, binding ->
      queryable
      |> join(:inner, [clients: clients], identity in assoc(clients, ^binding), as: ^binding)
      |> preload([clients: clients, identity: identity], identity: identity)
    end)
  end
end
