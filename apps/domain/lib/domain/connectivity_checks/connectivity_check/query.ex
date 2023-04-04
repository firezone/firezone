defmodule Domain.ConnectivityChecks.ConnectivityCheck.Query do
  use Domain, :query

  def all do
    from(users in Domain.ConnectivityChecks.ConnectivityCheck, as: :connectivity_checks)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [connectivity_checks: connectivity_checks], connectivity_checks.id == ^id)
  end

  def order_by_inserted_at(queryable \\ all()) do
    order_by(queryable, [connectivity_checks: connectivity_checks],
      desc: connectivity_checks.inserted_at
    )
  end

  def with_limit(queryable \\ all(), count) do
    limit(queryable, ^count)
  end
end
