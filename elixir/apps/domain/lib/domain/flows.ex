defmodule Domain.Flows do
  alias Domain.{Repo, PubSub}
  alias Domain.{Auth, Accounts, Actors, Clients, Gateways, Resources, Policies, Tokens}
  alias Domain.Flows.{Authorizer, Flow, Activity}
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
          gateway_remote_ip: gateway_remote_ip,
          expires_at: conformation_expires_at || expires_at
        })
        |> Repo.insert!()

      {:ok, resource, flow}
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

  def upsert_activities(activities) do
    {num, _} = Repo.insert_all(Activity, activities, on_conflict: :nothing)
    {:ok, num}
  end

  def fetch_last_activity_for(%Flow{} = flow, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_flows_permission()) do
      Activity.Query.all()
      |> Activity.Query.by_flow_id(flow.id)
      |> Activity.Query.first()
      |> Ecto.Query.order_by([activities: activities], desc: activities.window_ended_at)
      |> Repo.fetch(Activity.Query, opts)
    end
  end

  def list_flow_activities_for(assoc, subject, opts \\ [])

  def list_flow_activities_for(%Flow{} = flow, %Auth.Subject{} = subject, opts) do
    Activity.Query.all()
    |> Activity.Query.by_flow_id(flow.id)
    |> list_activities(subject, opts)
  end

  def list_flow_activities_for(%Accounts.Account{} = account, %Auth.Subject{} = subject, opts) do
    Activity.Query.all()
    |> Activity.Query.by_account_id(account.id)
    |> list_activities(subject, opts)
  end

  defp list_activities(queryable, subject, opts) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_flows_permission()) do
      queryable
      |> Authorizer.for_subject(Activity, subject)
      |> Repo.list(Activity.Query, opts)
    end
  end

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

  def expire_flows_for(%Policies.Policy{} = policy, %Auth.Subject{} = subject) do
    Flow.Query.all()
    |> Flow.Query.by_policy_id(policy.id)
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

  def expire_flows_for(actor_id, group_id) do
    Flow.Query.all()
    |> Flow.Query.by_actor_id(actor_id)
    |> Flow.Query.by_policy_actor_group_id(group_id)
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
    {_count, flows} =
      queryable
      |> Flow.Query.expire()
      |> Repo.update_all([])

    # TODO: WAL
    :ok =
      Enum.each(flows, fn flow ->
        :ok = broadcast_flow_expiration_event(flow)
      end)

    {:ok, flows}
  end

  ### PubSub

  defp flow_topic(%Flow{} = flow), do: flow_topic(flow.id)
  defp flow_topic(flow_id), do: "flows:#{flow_id}"

  def subscribe_to_flow_expiration_events(flow_or_id) do
    flow_or_id |> flow_topic() |> PubSub.subscribe()
  end

  def unsubscribe_to_flow_expiration_events(flow_or_id) do
    flow_or_id |> flow_topic() |> PubSub.subscribe()
  end

  # TODO: WAL
  defp broadcast_flow_expiration_event(flow) do
    flow
    |> flow_topic()
    |> PubSub.broadcast({:expire_flow, flow.id, flow.client_id, flow.resource_id})
  end
end
