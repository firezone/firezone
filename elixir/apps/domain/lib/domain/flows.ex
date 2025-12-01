defmodule Domain.Flows do
  alias Domain.{Repo, Safe, Client, Resource}
  alias Domain.{Auth, Gateway, Policies}
  alias Domain.Flows.Flow
  alias __MODULE__.DB
  require Ecto.Query
  require Logger

  # TODO: Optimization
  # Connection setup latency - doesn't need to block setting up flow. Authorizing the flow
  # is now handled in memory and this only logs it, so these can be done in parallel.
  def create_flow(
        %Client{
          id: client_id,
          account_id: account_id,
          actor_id: actor_id
        },
        %Gateway{
          id: gateway_id,
          last_seen_remote_ip: gateway_remote_ip,
          account_id: account_id
        },
        resource_id,
        policy_id,
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
    # Set the expiration time for the authorization. For normal user clients, this is 7 days, defined in Domain.Auth.
    # For service accounts using a headless client, it's configurable. This will always be set.
    # We always cap this by the subject's expires_at so that we synchronize removal of the flow on the gateway
    # with the websocket connection expiration on the client.

    changeset =
      Flow.Changeset.create(%{
        token_id: token_id,
        policy_id: policy_id,
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

    Safe.scoped(changeset, subject)
    |> Safe.insert()
  end

  # When the last flow in a Gateway's cache is deleted, we need to see if there are
  # any other policies potentially authorizing the client before sending reject_access.
  # This can happen if a Policy was created that grants redundant access to a client that
  # is already connected to the Resource, then the initial Policy is deleted.
  #
  # We need to create a new flow with the new Policy. Unfortunately getting the expiration
  # right is a bit tricky, since we need to synchronize this with the client's state.
  # If we expire the flow too early, the client will lose access to the Resource without
  # any change in client state. If we expire the flow too late, the client will have access
  # to the Resource beyond its intended expiration time.
  #
  # So, we use the minimum of either the policy condition or the origin flow's expiration time.
  # This will be much smoother once https://github.com/firezone/firezone/issues/10074 is implemented,
  # since we won't need to be so careful about reject_access messages to the gateway.
  def reauthorize_flow(%Flow{} = flow) do
    with client when not is_nil(client) <- DB.fetch_client_by_id!(flow.client_id),
         {:ok, token} <- DB.fetch_token_by_id(flow.token_id),
         {:ok, gateway} <- DB.fetch_gateway_by_id(flow.gateway_id),
         # We only want to reauthorize the resource for this gateway if the resource is still connected to its
         # site.
         policies when policies != [] <-
           Policies.all_policies_in_site_for_resource_id_and_actor_id!(
             flow.account_id,
             gateway.site_id,
             flow.resource_id,
             client.actor_id
           ),
         {:ok, policy, expires_at} <-
           Policies.longest_conforming_policy_for_client(policies, client, token, flow.expires_at),
         {:ok, membership} <-
           DB.fetch_membership_by_actor_id_and_group_id(
             client.actor_id,
             policy.actor_group_id
           ),
         {:ok, new_flow} <-
           Flow.Changeset.create(%{
             token_id: flow.token_id,
             policy_id: policy.id,
             client_id: flow.client_id,
             gateway_id: flow.gateway_id,
             resource_id: flow.resource_id,
             actor_group_membership_id: membership.id,
             account_id: flow.account_id,
             client_remote_ip: client.last_seen_remote_ip,
             client_user_agent: client.last_seen_user_agent,
             gateway_remote_ip: flow.gateway_remote_ip,
             expires_at: expires_at
           })
           |> Repo.insert() do
      Logger.info("Reauthorized flow",
        old_flow: inspect(flow),
        new_flow: inspect(new_flow)
      )

      {:ok, new_flow}
    else
      reason ->
        Logger.info("Failed to reauthorize flow",
          old_flow: inspect(flow),
          reason: inspect(reason)
        )

        :error
    end
  end

  def fetch_flow_by_id(id, %Auth.Subject{} = subject) do
    result =
      Flow.Query.all()
      |> Flow.Query.by_id(id)
      |> Safe.scoped(subject)
      |> Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      flow -> {:ok, flow}
    end
  end

  def all_gateway_flows_for_cache!(%Gateway{} = gateway) do
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

  def list_flows_for(%Resource{} = resource, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_resource_id(resource.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Client{} = client, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_client_id(client.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Domain.Actor{} = actor, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_actor_id(actor.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Gateway{} = gateway, %Auth.Subject{} = subject, opts) do
    Flow.Query.all()
    |> Flow.Query.by_gateway_id(gateway.id)
    |> list_flows(subject, opts)
  end

  defp list_flows(queryable, subject, opts) do
    queryable
    |> Safe.scoped(subject)
    |> Safe.list(Flow.Query, opts)
  end

  def delete_expired_flows do
    Flow.Query.all()
    |> Flow.Query.expired()
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Account{} = account) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(account.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Membership{} = membership) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(membership.account_id)
    |> Flow.Query.by_actor_group_membership_id(membership.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Client{} = client) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(client.account_id)
    |> Flow.Query.by_client_id(client.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Gateway{} = gateway) do
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

  def delete_flows_for(%Domain.Resource{} = resource) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(resource.account_id)
    |> Flow.Query.by_resource_id(resource.id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Resources.Connection{} = connection) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(connection.account_id)
    |> Flow.Query.by_resource_id(connection.resource_id)
    |> Flow.Query.by_site_id(connection.site_id)
    |> Repo.delete_all()
  end

  def delete_flows_for(%Domain.Token{account_id: nil}) do
    # Tokens without an account_id are not associated with any flows. I.e. global relay tokens
    {0, []}
  end

  def delete_flows_for(%Domain.Token{id: id, account_id: account_id}) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(account_id)
    |> Flow.Query.by_token_id(id)
    |> Repo.delete_all()
  end

  def delete_stale_flows_on_connect(%Client{} = client, resource_ids)
      when is_list(resource_ids) do
    Flow.Query.all()
    |> Flow.Query.by_account_id(client.account_id)
    |> Flow.Query.by_client_id(client.id)
    |> Flow.Query.by_not_in_resource_ids(resource_ids)
    |> Repo.delete_all()
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Repo, Gateway}
    alias Domain.Membership
    alias Domain.Client
    alias Domain.Token

    def fetch_membership_by_actor_id_and_group_id(actor_id, group_id) do
      from(m in Membership,
        where: m.actor_id == ^actor_id,
        where: m.group_id == ^group_id
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end

    def fetch_client_by_id!(id, _opts \\ []) do
      import Ecto.Query

      from(c in Client, as: :clients)
      |> where([clients: c], c.id == ^id)
      |> Repo.one()
    end

    def fetch_gateway_by_id(id) do
      result =
        from(g in Gateway, as: :gateways)
        |> where([gateways: g], g.id == ^id)
        |> Safe.unscoped()
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    end

    def fetch_token_by_id(id) do
      result =
        from(t in Token,
          where: t.id == ^id,
          where: t.expires_at > ^DateTime.utc_now() or is_nil(t.expires_at)
        )
        |> Safe.unscoped()
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        token -> {:ok, token}
      end
    end
  end
end
