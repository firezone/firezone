defmodule Domain.Resources.Connection.Query do
  use Domain, :query

  def all do
    from(connections in Domain.Resources.Connection, as: :connections)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [connections: connections], connections.account_id == ^account_id)
  end

  def by_resource_id(queryable \\ all(), resource_id) do
    where(queryable, [connections: connections], connections.resource_id == ^resource_id)
  end

  def by_gateway_group_id(queryable \\ all(), gateway_group_id) do
    where(
      queryable,
      [connections: connections],
      connections.gateway_group_id == ^gateway_group_id
    )
  end

  def with_assoc(queryable \\ all(), qual \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, qual, [connections: connections], a in assoc(connections, ^binding),
        as: ^binding
      )
    end)
  end
end
