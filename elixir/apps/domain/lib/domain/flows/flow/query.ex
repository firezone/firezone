defmodule Domain.Flows.Flow.Query do
  use Domain, :query

  def all do
    from(flows in Domain.Flows.Flow, as: :flows)
  end

  def not_expired(queryable \\ all()) do
    where(queryable, [flows: flows], flows.expires_at > fragment("timezone('UTC', NOW())"))
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

  def by_policy_actor_group_ids(queryable, actor_group_ids) do
    queryable
    |> with_joined_policy()
    |> where([policy: policy], policy.actor_group_id in ^actor_group_ids)
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

  def expire(queryable) do
    queryable
    |> not_expired()
    |> Ecto.Query.select([flows: flows], flows)
    |> Ecto.Query.update([flows: flows],
      set: [
        expires_at: fragment("LEAST(?, timezone('UTC', NOW()))", flows.expires_at)
      ]
    )
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

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :expiration,
        title: "Expired",
        type: :string,
        values: [
          {"Expired", "expired"},
          {"Not Expired", "not_expired"}
        ],
        fun: &filter_by_expired/2
      }
    ]

  def filter_by_expired(queryable, "expired") do
    {queryable, dynamic([flows: flows], flows.expires_at < fragment("timezone('UTC', NOW())"))}
  end

  def filter_by_expired(queryable, "not_expired") do
    {queryable, dynamic([flows: flows], flows.expires_at >= fragment("timezone('UTC', NOW())"))}
  end
end
