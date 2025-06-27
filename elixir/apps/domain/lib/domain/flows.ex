defmodule Domain.Flows do
  alias Domain.Repo
  alias Domain.{Auth, Actors, Clients, Gateways, Resources, Policies, Tokens}
  alias Domain.Flows.{Authorizer, Flow}
  require Ecto.Query
  require Logger

  def authorize_flow(
        %Clients.Client{
          id: client_id,
          account_id: account_id,
          actor_id: actor_id
        } = client,
        %Gateways.Gateway{
          id: gateway_id,
          last_seen_remote_ip: gateway_remote_ip,
          account_id: account_id
        },
        resource_id,
        %Auth.Subject{
          account: %{id: account_id},
          actor: %{id: actor_id},
          expires_at: expires_at,
          token_id: token_id,
          context: %Auth.Context{
            remote_ip: client_remote_ip,
            user_agent: client_user_agent
          }
        } = subject,
        opts \\ []
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.create_flows_permission()),
         {:ok, resource} <-
           Resources.fetch_and_authorize_resource_by_id(resource_id, subject, opts),
         {:ok, policy, conformation_expires_at} <- fetch_conforming_policy(resource, client) do
      flow =
        Flow.Changeset.create(%{
          token_id: token_id,
          policy_id: policy.id,
          client_id: client_id,
          gateway_id: gateway_id,
          resource_id: resource.id,
          account_id: account_id,
          client_remote_ip: client_remote_ip,
          client_user_agent: client_user_agent,
          gateway_remote_ip: gateway_remote_ip
        })
        |> Repo.insert!()

      expires_at = conformation_expires_at || expires_at

      {:ok, resource, flow, expires_at}
    end
  end

  defp fetch_conforming_policy(%Resources.Resource{} = resource, client) do
    Enum.reduce_while(resource.authorized_by_policies, {:error, []}, fn policy, {:error, acc} ->
      case Policies.ensure_client_conforms_policy_conditions(client, policy) do
        {:ok, expires_at} ->
          {:halt, {:ok, policy, expires_at}}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          {:cont, {:error, violated_properties ++ acc}}
      end
    end)
    |> case do
      {:error, violated_properties} ->
        {:error, {:forbidden, violated_properties: violated_properties}}

      {:ok, policy, expires_at} ->
        {:ok, policy, expires_at}
    end
  end

  def fetch_flow_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_flows_permission()),
         true <- Repo.valid_uuid?(id) do
      Flow.Query.all()
      |> Flow.Query.by_id(id)
      |> Authorizer.for_subject(Flow, subject)
      |> Repo.fetch(Flow.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_flows_for(assoc, subject, opts \\ [])

  def list_flows_for(%Policies.Policy{} = policy, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_policy_id(policy.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_resource_id(resource.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Clients.Client{} = client, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_client_id(client.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_actor_id(actor.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_gateway_id(gateway.id)
    |> list_flows(subject, opts)
  end

  defp list_flows(queryable, subject, opts) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_flows_permission()) do
      queryable
      |> Authorizer.for_subject(Flow, subject)
      |> Repo.list(Flow.Query, opts)
    end
  end

  # TODO: WAL
  # Remove all of the indexes used for these after flow expiration is moved to state
  # broadcasts

  def expire_flows_for(%Auth.Identity{} = identity) do
    Flow.Query.all()
    |> Flow.Query.by_identity_id(identity.id)
    |> expire_flows()
  end

  def expire_flows_for(%Clients.Client{} = client) do
    Flow.Query.all()
    |> Flow.Query.by_client_id(client.id)
    |> expire_flows()
  end

  def expire_flows_for(%Actors.Group{} = actor_group) do
    Flow.Query.all()
    |> Flow.Query.by_policy_actor_group_id(actor_group.id)
    |> expire_flows()
  end

  def expire_flows_for(%Tokens.Token{} = token, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_token_id(token.id)
    |> expire_flows(subject)
  end

  def expire_flows_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_actor_id(actor.id)
    |> expire_flows(subject)
  end

  def expire_flows_for(%Auth.Identity{} = identity, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_identity_id(identity.id)
    |> expire_flows(subject)
  end

  def expire_flows_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_resource_id(resource.id)
    |> expire_flows(subject)
  end

  def expire_flows_for(%Actors.Group{} = actor_group, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_policy_actor_group_id(actor_group.id)
    |> expire_flows(subject)
  end

  def expire_flows_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_identity_provider_id(provider.id)
    |> expire_flows(subject)
  end

  def expire_flows_for(account_id, actor_id, group_id) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(account_id)
    |> Flow.Query.by_actor_id(actor_id)
    |> Flow.Query.by_policy_actor_group_id(group_id)
    |> expire_flows()
  end

  def expire_flows_for_resource_id(account_id, resource_id) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(account_id)
    |> Flow.Query.by_resource_id(resource_id)
    |> expire_flows()
  end

  def expire_flows_for_policy_id(account_id, policy_id) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(account_id)
    |> Flow.Query.by_policy_id(policy_id)
    |> expire_flows()
  end

  defp expire_flows(queryable, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.create_flows_permission()) do
      queryable
      |> Authorizer.for_subject(Flow, subject)
      |> expire_flows()
    end
  end

  defp expire_flows(queryable) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        queryable
        |> Repo.stream()
        |> Stream.chunk_every(100)
        |> Enum.each(fn chunk ->
          Enum.each(chunk, &broadcast_flow_expiration/1)
        end)
      end)

    :ok
  end

  defp broadcast_flow_expiration(flow) do
    case Domain.PubSub.Flow.broadcast(
           flow.id,
           {:expire_flow, flow.id, flow.client_id, flow.resource_id}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to broadcast flow expiration",
          reason: inspect(reason),
          flow_id: flow.id
        )
    end
  end
end
