defmodule Domain.Flows do
  alias Domain.Repo
  alias Domain.{Auth, Clients, Gateways, Resources, Policies}
  alias Domain.Flows.{Authorizer, Flow}
  require Ecto.Query

  def authorize_flow(
        %Clients.Client{
          id: client_id,
          account_id: account_id,
          actor_id: actor_id,
          identity_id: identity_id
        },
        %Gateways.Gateway{
          id: gateway_id,
          last_seen_remote_ip: destination_remote_ip,
          account_id: account_id
        },
        id,
        %Auth.Subject{
          account: %{id: account_id},
          actor: %{id: actor_id},
          identity: %{id: identity_id},
          expires_at: expires_at,
          context: %Auth.Context{
            remote_ip: source_remote_ip,
            user_agent: source_user_agent
          }
        } = subject,
        opts \\ []
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.create_flows_permission()),
         {:ok, resource} <- Resources.fetch_and_authorize_resource_by_id(id, subject, opts) do
      flow =
        Flow.Changeset.create(%{
          policy_id: resource.authorized_by_policy.id,
          client_id: client_id,
          gateway_id: gateway_id,
          resource_id: resource.id,
          account_id: account_id,
          source_remote_ip: source_remote_ip,
          source_user_agent: source_user_agent,
          destination_remote_ip: destination_remote_ip,
          expires_at: expires_at
        })
        |> Repo.insert!()

      {:ok, resource, flow}
    end
  end

  def list_flows_for(assoc, subject, opts \\ [])

  def list_flows_for(%Policies.Policy{} = policy, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_policy_id(policy.id)
    |> list(subject, opts)
  end

  def list_flows_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_resource_id(resource.id)
    |> list(subject, opts)
  end

  def list_flows_for(%Clients.Client{} = client, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_client_id(client.id)
    |> list(subject, opts)
  end

  def list_flows_for(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_gateway_id(gateway.id)
    |> list(subject, opts)
  end

  defp list(queryable, subject, opts) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_flows_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, flows} =
        queryable
        |> Authorizer.for_subject(subject)
        |> Ecto.Query.order_by([flows: flows], desc: flows.inserted_at, desc: flows.id)
        |> Ecto.Query.limit(50)
        |> Repo.list()

      {:ok, Repo.preload(flows, preload)}
    end
  end
end
