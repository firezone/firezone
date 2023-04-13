defmodule Domain.Clients.Client.Query do
  use Domain, :query

  def all do
    from(clients in Domain.Clients.Client, as: :clients)
    |> where([clients: clients], is_nil(clients.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [clients: clients], clients.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [clients: clients], clients.user_id == ^user_id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [clients: clients], clients.account_id == ^account_id)
  end

  def returning_all(queryable \\ all()) do
    select(queryable, [clients: clients], clients)
  end

  def with_preloaded_user(queryable \\ all()) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      queryable
      |> join(:inner, [clients: clients], user in assoc(clients, ^binding), as: ^binding)
      |> preload([clients: clients, user: user], user: user)
    end)
  end
end
