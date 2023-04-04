defmodule Domain.Auth.MFA.Method.Query do
  use Domain, :query

  def all do
    from(users in Domain.Auth.MFA.Method, as: :methods)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [methods: methods], methods.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [methods: methods], methods.user_id == ^user_id)
  end

  def by_type(queryable \\ all(), type) do
    where(queryable, [methods: methods], methods.type == ^type)
  end

  def order_by_last_usage(queryable \\ all()) do
    order_by(queryable, [methods: methods], desc: methods.last_used_at)
  end

  def select_distinct_user_ids_count(queryable \\ all()) do
    queryable
    |> select([methods: methods], count(methods.user_id, :distinct))
  end

  def with_limit(queryable \\ all(), count) do
    limit(queryable, ^count)
  end
end
