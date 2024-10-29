defmodule Domain.Policies do
  alias Domain.{Repo, PubSub}
  alias Domain.{Auth, Accounts, Actors, Clients, Resources, Flows}
  alias Domain.Policies.{Authorizer, Policy, Condition}

  def fetch_policy_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_policies_permission(),
         Authorizer.view_available_policies_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Policy.Query.all()
      |> Policy.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_policy_by_id_or_persistent(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_policies_permission(),
         Authorizer.view_available_policies_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Policy.Query.all()
      |> Policy.Query.by_id_or_persistent_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_policies(%Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_policies_permission(),
         Authorizer.view_available_policies_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Policy.Query, opts)
    end
  end

  def new_policy(attrs, %Auth.Subject{} = subject) do
    Policy.Changeset.create(attrs, subject)
  end

  def create_policy(attrs, %Auth.Subject{} = subject) do
    required_permissions = {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Changeset.create(attrs, subject)
      |> Repo.insert()
      |> case do
        {:ok, policy} ->
          :ok = broadcast_policy_events(:create, policy)
          {:ok, policy}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def change_policy(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    case Policy.Changeset.update_or_replace(policy, attrs, subject) do
      {update_changeset, nil} -> update_changeset
      {_update_changeset, create_changeset} -> create_changeset
    end
  end

  def update_or_replace_policy(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         :ok <- ensure_has_access_to(subject, policy) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update_or_replace(Policy.Query,
        with: &Policy.Changeset.update_or_replace(&1, attrs, subject),
        on_replace: fn repo, updated_policy, created_policy ->
          Ecto.Changeset.change(updated_policy, replaced_by_policy_id: created_policy.id)
          |> repo.update()
        end,
        after_update_commit: &broadcast_policy_events(:update, &1),
        after_replace_commit: fn {replaced_policy, created_policy}, _changesets ->
          {:ok, _flows} = Flows.expire_flows_for(replaced_policy, subject)
          :ok = broadcast_policy_events(:delete, replaced_policy)
          :ok = broadcast_policy_events(:create, created_policy)
        end
      )
    end
  end

  def disable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Policy.Query,
        with: &Policy.Changeset.disable(&1, subject),
        after_commit: &broadcast_policy_events(:disable, &1)
      )
      |> case do
        {:ok, policy} ->
          {:ok, _flows} = Flows.expire_flows_for(policy, subject)
          {:ok, policy}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def enable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Policy.Query,
        with: &Policy.Changeset.enable/1,
        after_commit: &broadcast_policy_events(:enable, &1)
      )
    end
  end

  def delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_id(policy.id)
    |> delete_policies(policy, subject)
    |> case do
      {:ok, [policy]} -> {:ok, policy}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_policies_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_resource_id(resource.id)
    |> delete_policies(resource, subject)
  end

  def delete_policies_for(%Actors.Group{} = actor_group, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> delete_policies(actor_group, subject)
  end

  def delete_policies_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_provider_id(provider.id)
    |> delete_policies(provider, subject)
  end

  def delete_policies_for(%Actors.Group{} = actor_group) do
    {:ok, _flows} = Flows.expire_flows_for(actor_group)

    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> delete_policies()
  end

  defp delete_policies(queryable, assoc, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      {:ok, _flows} = Flows.expire_flows_for(assoc, subject)

      queryable
      |> Authorizer.for_subject(subject)
      |> delete_policies()
    end
  end

  defp delete_policies(queryable) do
    {_count, policies} =
      queryable
      |> Policy.Query.delete()
      |> Repo.update_all([])

    :ok =
      Enum.each(policies, fn policy ->
        :ok = broadcast_policy_events(:delete, policy)
      end)

    {:ok, policies}
  end

  def pre_filter_non_conforming_resources(resources, %Clients.Client{} = client) do
    resources
    |> Enum.flat_map(fn resource ->
      case client_conforms_any_on_connect?(client, resource.authorized_by_policies) do
        true -> [resource]
        false -> []
      end
    end)
  end

  def client_conforms_any_on_connect?(%Clients.Client{} = client, policies) do
    Enum.any?(policies, fn policy ->
      policy.conditions
      |> Enum.filter(&Condition.Evaluator.evaluable_on_connect?/1)
      |> Condition.Evaluator.ensure_conforms(client)
      |> case do
        {:ok, _expires_at} -> true
        {:error, _violated_properties} -> false
      end
    end)
  end

  def ensure_client_conforms_policy_conditions(%Clients.Client{} = client, %Policy{} = policy) do
    case Condition.Evaluator.ensure_conforms(policy.conditions, client) do
      {:ok, expires_at} ->
        {:ok, expires_at}

      {:error, violated_properties} ->
        {:error, {:forbidden, violated_properties: violated_properties}}
    end
  end

  def ensure_has_access_to(%Auth.Subject{} = subject, %Policy{} = policy) do
    if subject.account.id == policy.account_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  ### PubSub

  defp policy_topic(%Policy{} = policy), do: policy_topic(policy.id)
  defp policy_topic(policy_id), do: "policy:#{policy_id}"

  defp account_topic(%Accounts.Account{} = account), do: account_topic(account.id)
  defp account_topic(account_id), do: "account_policies:#{account_id}"

  defp actor_group_topic(%Actors.Group{} = actor_group), do: actor_group_topic(actor_group.id)
  defp actor_group_topic(actor_group_id), do: "actor_group_policies:#{actor_group_id}"

  defp actor_topic(%Actors.Actor{} = actor), do: actor_topic(actor.id)
  defp actor_topic(actor_id), do: "actor_policies:#{actor_id}"

  def subscribe_to_events_for_policy(policy_or_id) do
    policy_or_id |> policy_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_events_for_policy(policy_or_id) do
    policy_or_id |> policy_topic() |> PubSub.unsubscribe()
  end

  def subscribe_to_events_for_account(account_or_id) do
    account_or_id |> account_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_events_for_account(account_or_id) do
    account_or_id |> account_topic() |> PubSub.unsubscribe()
  end

  def subscribe_to_events_for_actor(actor_or_id) do
    actor_or_id |> actor_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_events_for_actor(actor_or_id) do
    actor_or_id |> actor_topic() |> PubSub.unsubscribe()
  end

  def subscribe_to_events_for_actor_group(actor_group_or_id) do
    actor_group_or_id |> actor_group_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_events_for_actor_group(actor_group_or_id) do
    actor_group_or_id |> actor_group_topic() |> PubSub.unsubscribe()
  end

  defp broadcast_policy_events(action, %Policy{} = policy) do
    payload = {:"#{action}_policy", policy.id}
    :ok = broadcast_to_policy(policy, payload)
    :ok = broadcast_to_account(policy.account_id, payload)
    :ok = broadcast_to_actor_group(policy.actor_group_id, access_event(action, policy))
    :ok
  end

  def broadcast_access_events_for(action, actor_id, group_id) do
    {:ok, _flows} = maybe_expire_flows(action, actor_id, group_id)

    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(group_id)
    |> Repo.all()
    |> Enum.each(fn policy ->
      :ok = broadcast_to_actor(actor_id, access_event(action, policy))
    end)
  end

  defp access_event(action, %Policy{} = policy) when action in [:create, :enable] do
    {:allow_access, policy.id, policy.actor_group_id, policy.resource_id}
  end

  defp access_event(action, %Policy{} = policy) when action in [:delete, :disable] do
    {:reject_access, policy.id, policy.actor_group_id, policy.resource_id}
  end

  defp access_event(:update, %Policy{}) do
    nil
  end

  defp maybe_expire_flows(action, actor_id, group_id) when action in [:delete, :disable] do
    Flows.expire_flows_for(actor_id, group_id)
  end

  defp maybe_expire_flows(_action, _actor_id, _group_id) do
    {:ok, []}
  end

  defp broadcast_to_policy(policy_or_id, payload) do
    policy_or_id
    |> policy_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_account(account_or_id, payload) do
    account_or_id
    |> account_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_actor(actor_or_id, payload) do
    actor_or_id
    |> actor_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_actor_group(_actor_group_or_id, nil) do
    :ok
  end

  defp broadcast_to_actor_group(actor_group_or_id, payload) do
    actor_group_or_id
    |> actor_group_topic()
    |> PubSub.broadcast(payload)
  end
end
