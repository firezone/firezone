defmodule Domain.Flows do
  alias Domain.Repo
  alias Domain.{Auth, Actors, Clients, Gateways, Resources, Policies}
  alias Domain.Flows.{Authorizer, Flow}
  require Ecto.Query
  require Logger

  # TODO: Connection setup latency
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
         {:ok, policy, conformation_expires_at} <- fetch_conforming_policy(resource, client),
         {:ok, membership} <-
           Actors.fetch_membership_by_actor_id_and_group_id(actor_id, policy.actor_group_id) do
      flow =
        Flow.Changeset.create(%{
          token_id: token_id,
          policy_id: policy.id,
          client_id: client_id,
          gateway_id: gateway_id,
          resource_id: resource.id,
          actor_group_membership_id: membership.id,
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

  def all_gateway_flows_for_cache!(%Gateways.Gateway{} = gateway) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(gateway.account_id)
    |> Flow.Query.by_gateway_id(gateway.id)
    |> Flow.Query.within_2_weeks()
    |> Repo.all()
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
end
