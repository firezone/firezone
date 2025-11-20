defmodule Domain.Auth.Identity.Query do
  use Domain, :query
  alias Domain.Repo

  def all do
    from(identities in Domain.Auth.Identity, as: :identities)
  end

  def not_disabled(queryable \\ all()) do
    queryable
    |> with_assoc(:inner, :actor)
    |> where([actor: actor], is_nil(actor.disabled_at))
  end

  def by_id(queryable, id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [identities: identities], identities.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [identities: identities], identities.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [identities: identities], identities.account_id == ^account_id)
  end

  def by_actor_id(queryable, {:in, actor_ids}) do
    where(queryable, [identities: identities], identities.actor_id in ^actor_ids)
  end

  def by_actor_id(queryable, actor_id) do
    where(queryable, [identities: identities], identities.actor_id == ^actor_id)
  end

  def lock(queryable) do
    lock(queryable, "FOR UPDATE")
  end

  def returning_ids(queryable) do
    select(queryable, [identities: identities], identities.id)
  end

  def returning_actor_ids(queryable) do
    select(queryable, [identities: identities], identities.actor_id)
  end

  def returning_distinct_actor_ids(queryable) do
    queryable
    |> select([identities: identities], identities.actor_id)
    |> distinct(true)
  end

  def with_preloaded_assoc(queryable, type \\ :left, assoc) do
    queryable
    |> with_assoc(type, assoc)
    |> preload([{^assoc, assoc}], [{^assoc, assoc}])
  end

  def with_assoc(queryable, type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [identities: identities], a in assoc(identities, ^binding), as: ^binding)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:identities, :asc, :inserted_at},
      {:identities, :asc, :id}
    ]
end
