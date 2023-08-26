defmodule Domain.Actors.Actor.Query do
  use Domain, :query

  def all do
    from(actors in Domain.Actors.Actor, as: :actors)
    |> where([actors: actors], is_nil(actors.deleted_at))
  end

  def by_id(queryable \\ all(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [actors: actors], actors.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [actors: actors], actors.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [actors: actors], actors.account_id == ^account_id)
  end

  def by_type(queryable \\ all(), type) do
    where(queryable, [actors: actors], actors.type == ^type)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [actors: actors], is_nil(actors.disabled_at))
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end

  def with_assoc(queryable \\ all(), qual \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, qual, [actors: actors], a in assoc(actors, ^binding), as: ^binding)
    end)
  end
end
