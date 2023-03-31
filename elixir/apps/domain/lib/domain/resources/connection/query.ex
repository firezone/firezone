defmodule Domain.Resources.Connection.Query do
  use Domain, :query

  def all do
    from(connections in Domain.Resources.Connection, as: :connections)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [connections: connections], connections.account_id == ^account_id)
  end
end
