defmodule Domain.Flows.Flow.Query do
  use Domain, :query

  def all do
    from(flows in Domain.Flows.Flow, as: :flows)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [flows: flows], flows.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [flows: flows], flows.account_id == ^account_id)
  end

  def by_policy_id(queryable \\ all(), policy_id) do
    where(queryable, [flows: flows], flows.policy_id == ^policy_id)
  end

  def by_resource_id(queryable \\ all(), resource_id) do
    where(queryable, [flows: flows], flows.resource_id == ^resource_id)
  end

  def by_client_id(queryable \\ all(), client_id) do
    where(queryable, [flows: flows], flows.client_id == ^client_id)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    queryable
    |> with_joined_client()
    |> where([client: client], client.actor_id == ^actor_id)
  end

  def by_gateway_id(queryable \\ all(), gateway_id) do
    where(queryable, [flows: flows], flows.gateway_id == ^gateway_id)
  end

  def with_joined_client(queryable \\ all()) do
    with_named_binding(queryable, :client, fn queryable, binding ->
      join(queryable, :inner, [flows: flows], client in assoc(flows, ^binding), as: ^binding)
    end)
  end
end
