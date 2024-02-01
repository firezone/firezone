defmodule Domain.Flows.Flow.Query do
  use Domain, :query

  def all do
    from(flows in Domain.Flows.Flow, as: :flows)
  end

  def not_expired(queryable \\ all()) do
    where(queryable, [flows: flows], flows.expires_at > fragment("NOW()"))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [flows: flows], flows.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [flows: flows], flows.account_id == ^account_id)
  end

  def by_token_id(queryable \\ all(), token_id) do
    where(queryable, [flows: flows], flows.token_id == ^token_id)
  end

  def by_policy_id(queryable \\ all(), policy_id) do
    where(queryable, [flows: flows], flows.policy_id == ^policy_id)
  end

  def by_policy_actor_group_id(queryable \\ all(), actor_group_id) do
    queryable
    |> with_joined_policy()
    |> where([policy: policy], policy.actor_group_id == ^actor_group_id)
  end

  def by_identity_id(queryable \\ all(), identity_id) do
    queryable
    |> with_joined_client()
    |> where([client: client], client.identity_id == ^identity_id)
  end

  def by_identity_provider_id(queryable \\ all(), provider_id) do
    queryable
    |> with_joined_client_identity()
    |> where([identity: identity], identity.provider_id == ^provider_id)
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

  def expire(queryable \\ all()) do
    queryable
    |> not_expired()
    |> Ecto.Query.select([flows: flows], flows)
    |> Ecto.Query.update([flows: flows],
      set: [
        expires_at: fragment("LEAST(?, NOW())", flows.expires_at)
      ]
    )
  end

  def with_joined_policy(queryable \\ all()) do
    with_named_binding(queryable, :policy, fn queryable, binding ->
      join(queryable, :inner, [flows: flows], policy in assoc(flows, ^binding), as: ^binding)
    end)
  end

  def with_joined_client(queryable \\ all()) do
    with_named_binding(queryable, :client, fn queryable, binding ->
      join(queryable, :inner, [flows: flows], client in assoc(flows, ^binding), as: ^binding)
    end)
  end

  def with_joined_client_identity(queryable \\ all()) do
    queryable
    |> with_joined_client()
    |> with_named_binding(:identity, fn queryable, binding ->
      join(queryable, :inner, [client: client], identity in assoc(client, ^binding), as: ^binding)
    end)
  end
end
