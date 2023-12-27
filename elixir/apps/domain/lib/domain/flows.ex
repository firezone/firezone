defmodule Domain.Flows do
  alias Domain.{Repo, Validator}
  alias Domain.{Auth, Accounts, Actors, Clients, Gateways, Resources, Policies}
  alias Domain.Flows.{Authorizer, Flow, Activity}
  require Ecto.Query
  require Logger

  def authorize_flow(client, gateway, id, subject, opts \\ [])

  def authorize_flow(
        %Clients.Client{
          id: client_id,
          account_id: account_id,
          actor_id: actor_id,
          identity_id: identity_id
        },
        %Gateways.Gateway{
          id: gateway_id,
          last_seen_remote_ip: gateway_remote_ip,
          account_id: account_id
        },
        id,
        %Auth.Subject{
          account: %{id: account_id},
          actor: %{id: actor_id},
          identity: %{id: identity_id},
          expires_at: expires_at,
          context: %Auth.Context{
            remote_ip: client_remote_ip,
            user_agent: client_user_agent
          }
        } = subject,
        opts
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
          client_remote_ip: client_remote_ip,
          client_user_agent: client_user_agent,
          gateway_remote_ip: gateway_remote_ip,
          expires_at: expires_at
        })
        |> Repo.insert!()

      {:ok, resource, flow}
    end
  end

  def authorize_flow(client, gateway, id, subject, _opts) do
    Logger.error("authorize_flow/4 called with invalid arguments",
      id: id,
      client: %{
        id: client.id,
        account_id: client.account_id,
        actor_id: client.actor_id,
        identity_id: client.identity_id
      },
      gateway: %{
        id: gateway.id,
        account_id: gateway.account_id
      },
      subject: %{
        account: %{id: subject.account.id, slug: subject.account.slug},
        actor: %{id: subject.actor.id, type: subject.actor.type},
        identity: %{id: subject.identity.id}
      }
    )

    {:error, :internal_error}
  end

  def fetch_flow_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_flows_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Flow.Query.by_id(id)
      |> Authorizer.for_subject(Flow, subject)
      |> Repo.fetch()
      |> case do
        {:ok, resource} -> {:ok, Repo.preload(resource, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_flows_for(assoc, subject, opts \\ [])

  def list_flows_for(%Policies.Policy{} = policy, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_policy_id(policy.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_resource_id(resource.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Clients.Client{} = client, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_client_id(client.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_actor_id(actor.id)
    |> list_flows(subject, opts)
  end

  def list_flows_for(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject, opts) do
    Flow.Query.by_gateway_id(gateway.id)
    |> list_flows(subject, opts)
  end

  defp list_flows(queryable, subject, opts) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_flows_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, flows} =
        queryable
        |> Authorizer.for_subject(Flow, subject)
        |> Ecto.Query.order_by([flows: flows], desc: flows.inserted_at, desc: flows.id)
        |> Ecto.Query.limit(50)
        |> Repo.list()

      {:ok, Repo.preload(flows, preload)}
    end
  end

  def upsert_activities(activities) do
    {num, _} = Repo.insert_all(Activity, activities, on_conflict: :nothing)

    {:ok, num}
  end

  def list_flow_activities_for(
        %Flow{} = flow,
        ended_after,
        started_before,
        %Auth.Subject{} = subject
      ) do
    Activity.Query.by_flow_id(flow.id)
    |> list_activities(ended_after, started_before, subject)
  end

  def list_flow_activities_for(
        %Accounts.Account{} = account,
        ended_after,
        started_before,
        %Auth.Subject{} = subject
      ) do
    Activity.Query.by_account_id(account.id)
    |> list_activities(ended_after, started_before, subject)
  end

  defp list_activities(queryable, ended_after, started_before, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_flows_permission()) do
      queryable
      |> Activity.Query.by_window_ended_at({:greater_than, ended_after})
      |> Activity.Query.by_window_started_at({:less_than, started_before})
      |> Authorizer.for_subject(Activity, subject)
      |> Ecto.Query.order_by([activities: activities], asc: activities.window_started_at)
      |> Repo.list()
    end
  end
end
