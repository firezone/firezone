defmodule FzHttp.Auth.OIDC.Connection.Query do
  use FzHttp, :query

  def all do
    from(connection in FzHttp.Auth.OIDC.Connection, as: :connection)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [connection: connection], connection.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [connection: connection], connection.user_id == ^user_id)
  end
end
