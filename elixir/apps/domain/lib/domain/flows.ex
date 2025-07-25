defmodule Domain.Flows do
  alias Domain.Repo
  alias Domain.{Auth, Actors, Clients, Gateways, Resources, Policies}
  alias Domain.Flows.{Authorizer, Flow}
  require Ecto.Query
  require Logger

  # TODO: Optimization
  # Connection setup latency - doesn't need to block setting up flow. Authorizing the flow
  # is now handled in memory and this only logs it, so these can be done in parallel.
  def create_flow(
        %Clients.Client{
          id: client_id,
          account_id: account_id,
          actor_id: actor_id
        },
        %Gateways.Gateway{
          id: gateway_id,
          last_seen_remote_ip: gateway_remote_ip,
          account_id: account_id
        },
        resource_id,
        %Policies.Policy{} = policy,
        membership_id,
        %Auth.Subject{
          account: %{id: account_id},
          actor: %{id: actor_id},
          token_id: token_id,
          context: %Auth.Context{
            remote_ip: client_remote_ip,
            user_agent: client_user_agent
          }
        } = subject,
        expires_at
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.create_flows_permission()) do
      flow =
        Flow.Changeset.create(%{
          token_id: token_id,
          policy_id: policy.id,
          client_id: client_id,
          gateway_id: gateway_id,
          resource_id: resource_id,
          actor_group_membership_id: membership_id,
          account_id: account_id,
          client_remote_ip: client_remote_ip,
          client_user_agent: client_user_agent,
          gateway_remote_ip: gateway_remote_ip,
          expires_at: expires_at
        })
        |> Repo.insert!()

      {:ok, flow}
    end
  end

  # When the last flow in a Gateway's cache is deleted, we need to see if there are
  # any other policies potentially authorizing the client before sending reject_access.
  # This can happen if a Policy was created that grants redundant access to a client that
  # is already connected to the Resource, then the initial Policy is deleted.
  #
  # We need to create a new flow with the new Policy but the same (or shorter) expiration as
  # the old flow.
  def reauthorize_flow(%Flow{} = flow) do
    with {:ok, client} <- Clients.fetch_client_by_id(flow.client_id, preload: :identity),
         policies when policies != [] <-
           Policies.all_policies_for_resource_id!(
             flow.account_id,
             flow.resource_id
           ),
         conforming_policies when conforming_policies != [] <-
           Policies.filter_by_conforming_policies_for_client(policies, client),
         policy <- Enum.at(conforming_policies, 0),
         {:ok, expires_at} <- Policies.ensure_client_conforms_policy_conditions(client, policy),
         {:ok, membership} <-
           Actors.fetch_membership_by_actor_id_and_group_id(
             client.actor_id,
             policy.actor_group_id
           ),
         {:ok, new_flow} <-
           Flow.Changeset.create(%{
             token_id: flow.token_id,
             policy_id: Enum.at(conforming_policies, 0).id,
             client_id: flow.client_id,
             gateway_id: flow.gateway_id,
             resource_id: flow.resource_id,
             actor_group_membership_id: membership.id,
             account_id: flow.account_id,
             client_remote_ip: client.last_seen_remote_ip,
             client_user_agent: client.last_seen_user_agent,
             gateway_remote_ip: flow.gateway_remote_ip,
             expires_at: expires_at || flow.expires_at
           })
           |> Repo.insert() do
      {:ok, new_flow}
    else
      reason ->
        Logger.info("Failed to reauthorize flow: #{inspect(reason)}")
        {:error, :forbidden}
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
    |> Flow.Query.not_expired()
    |> Flow.Query.for_cache()
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

  def delete_flows_for(%Domain.Accounts.Account{} = account) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(account.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Actors.Membership{} = membership) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(membership.account_id)
    |> Flow.Query.by_actor_group_membership_id(membership.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Clients.Client{} = client) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(client.account_id)
    |> Flow.Query.by_client_id(client.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Gateways.Gateway{} = gateway) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(gateway.account_id)
    |> Flow.Query.by_gateway_id(gateway.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Policies.Policy{} = policy) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(policy.account_id)
    |> Flow.Query.by_policy_id(policy.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Resources.Resource{} = resource) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(resource.account_id)
    |> Flow.Query.by_resource_id(resource.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Tokens.Token{} = token) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(token.account_id)
    |> Flow.Query.by_token_id(token.id)
    |> Repo.delete_all()
  end

  def delete_stale_flows_on_connect(%Clients.Client{} = client, resources)
      when is_list(resources) do
    authorized_resource_ids = Enum.map(resources, & &1.id)

    Flow.Query.all()
    |> Flow.Query.by_account_id(client.account_id)
    |> Flow.Query.by_client_id(client.id)
    |> Flow.Query.by_not_in_resource_ids(authorized_resource_ids)
    |> Repo.delete_all()
  end
end
