defmodule Domain.Auth.OIDC.Connection.Query do
  use Domain, :query

  def all do
    from(connection in Domain.Auth.OIDC.Connection, as: :connection)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [connection: connection], connection.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [connection: connection], connection.user_id == ^user_id)
  end
end
