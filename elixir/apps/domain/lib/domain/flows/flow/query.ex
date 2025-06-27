defmodule Domain.Flows.Flow.Query do
  use Domain, :query

  def all do
    from(flows in Domain.Flows.Flow, as: :flows)
  end

  def by_id(queryable, id) do
    where(queryable, [flows: flows], flows.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [flows: flows], flows.account_id == ^account_id)
  end

  def by_token_id(queryable, token_id) do
    where(queryable, [flows: flows], flows.token_id == ^token_id)
  end

  def by_policy_id(queryable, policy_id) do
    where(queryable, [flows: flows], flows.policy_id == ^policy_id)
  end

  def by_policy_actor_group_id(queryable, actor_group_id) do
    queryable
    |> with_joined_policy()
    |> where([policy: policy], policy.actor_group_id == ^actor_group_id)
  end

  def by_identity_id(queryable, identity_id) do
    queryable
    |> with_joined_client()
    |> where([client: client], client.identity_id == ^identity_id)
  end

  def by_identity_provider_id(queryable, provider_id) do
    queryable
    |> with_joined_client_identity()
    |> where([identity: identity], identity.provider_id == ^provider_id)
  end

  def by_resource_id(queryable, resource_id) do
    where(queryable, [flows: flows], flows.resource_id == ^resource_id)
  end

  def by_client_id(queryable, client_id) do
    where(queryable, [flows: flows], flows.client_id == ^client_id)
  end

  def by_actor_id(queryable, actor_id) do
    queryable
    |> with_joined_client()
    |> where([client: client], client.actor_id == ^actor_id)
  end

  def by_gateway_id(queryable, gateway_id) do
    where(queryable, [flows: flows], flows.gateway_id == ^gateway_id)
  end

  def with_joined_policy(queryable) do
    with_named_binding(queryable, :policy, fn queryable, binding ->
      join(queryable, :inner, [flows: flows], policy in assoc(flows, ^binding), as: ^binding)
    end)
  end

  def with_joined_client(queryable) do
    with_named_binding(queryable, :client, fn queryable, binding ->
      join(queryable, :inner, [flows: flows], client in assoc(flows, ^binding), as: ^binding)
    end)
  end

  def with_joined_client_identity(queryable) do
    queryable
    |> with_joined_client()
    |> with_named_binding(:identity, fn queryable, binding ->
      join(queryable, :inner, [client: client], identity in assoc(client, ^binding), as: ^binding)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:flows, :desc, :inserted_at},
      {:flows, :asc, :id}
    ]
end
