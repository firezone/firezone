defmodule Domain.Policies do
  alias Domain.Repo
  alias Domain.{Auth, Actors, Cache.Cacheable, Clients, Resources}
  alias Domain.Policies.{Authorizer, Policy, Condition}
  require Logger

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

  def fetch_policy_by_id_or_persistent_id(id, %Auth.Subject{} = subject, opts \\ []) do
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

  def all_policies_for_actor_id!(actor_id) do
    Policy.Query.not_disabled()
    |> Policy.Query.by_actor_id(actor_id)
    |> Policy.Query.with_preloaded_resource_gateway_groups()
    |> Repo.all()
  end

  def all_policies_for_actor_group_id!(account_id, actor_group_id) do
    Policy.Query.not_disabled()
    |> Policy.Query.by_account_id(account_id)
    |> Policy.Query.by_actor_group_id(actor_group_id)
    |> Policy.Query.with_preloaded_resource_gateway_groups()
    |> Repo.all()
  end

  def all_policies_in_gateway_group_for_resource_id_and_actor_id!(
        account_id,
        gateway_group_id,
        resource_id,
        actor_id
      ) do
    Policy.Query.not_disabled()
    |> Policy.Query.by_account_id(account_id)
    |> Policy.Query.by_resource_id(resource_id)
    |> Policy.Query.by_gateway_group_id(gateway_group_id)
    |> Policy.Query.by_actor_id(actor_id)
    |> Repo.all()
  end

  def new_policy(attrs, %Auth.Subject{} = subject) do
    Policy.Changeset.create(attrs, subject)
  end

  def create_policy(attrs, %Auth.Subject{} = subject) do
    required_permissions = {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def change_policy(%Policy{} = policy, attrs) do
    Policy.Changeset.update(policy, attrs)
  end

  def update_policy(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         :ok <- ensure_has_access_to(subject, policy) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Policy.Query,
        with: &Policy.Changeset.update(&1, attrs)
      )
    end
  end

  def disable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Policy.Query,
        with: &Policy.Changeset.disable(&1, subject)
      )
    end
  end

  def enable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Policy.Query,
        with: &Policy.Changeset.enable/1
      )
    end
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def soft_delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_id(policy.id)
    |> soft_delete_policies(subject)
    |> case do
      {:ok, [policy]} -> {:ok, policy}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Authorizer.ensure_has_access_to(policy, subject) do
      Repo.delete(policy, stale_error_field: false)
    end
  end

  # TODO: HARD-DELETE - Should not be needed after hard delete is implemented
  def delete_policies_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.all()
      |> Policy.Query.by_resource_id(resource.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {count, nil} ->
          {:ok, count}

        error ->
          Logger.error("Unknown error while deleting policies for resource",
            account_id: resource.account_id,
            actor_id: subject.actor.id,
            resource_id: resource.id,
            reason: inspect(error)
          )

          {:error, "unknown error deleting policies for resource"}
      end
    end
  end

  # TODO: HARD-DELETE - Should not be needed after hard delete is implemented
  def delete_policies_for(%Actors.Group{} = actor_group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.all()
      |> Policy.Query.by_actor_group_id(actor_group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {count, nil} ->
          {:ok, count}

        error ->
          Logger.error("Unknown error while deleting policies for group",
            account_id: actor_group.account_id,
            actor_id: subject.actor.id,
            group_id: actor_group.id,
            reason: inspect(error)
          )

          {:error, "unknown error deleting policies for resource"}
      end
    end
  end

  # TODO: HARD-DELETE - Should not be needed after hard delete is implemented
  def delete_policies_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.all()
      |> Policy.Query.by_actor_group_provider_id(provider.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {count, nil} ->
          {:ok, count}

        error ->
          Logger.error("Unknown error while deleting policies for provider",
            account_id: provider.account_id,
            actor_id: subject.actor.id,
            provider_id: provider.id,
            reason: inspect(error)
          )

          {:error, "unknown error deleting policies for resource"}
      end
    end
  end

  # TODO: HARD-DELETE - Should not be needed after hard delete is implemented
  def delete_policies_for(%Actors.Group{} = actor_group) do
    Policy.Query.all()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> Repo.delete_all()
    |> case do
      {count, nil} ->
        {:ok, count}

      error ->
        Logger.error("Unknown error while deleting policies for group",
          account_id: actor_group.account_id,
          group_id: actor_group.id,
          reason: inspect(error)
        )

        {:error, "unknown error deleting policies for resource"}
    end
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def soft_delete_policies_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_resource_id(resource.id)
    |> soft_delete_policies(subject)
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def soft_delete_policies_for(%Actors.Group{} = actor_group, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> soft_delete_policies(subject)
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def soft_delete_policies_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_provider_id(provider.id)
    |> soft_delete_policies(subject)
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def soft_delete_policies_for(%Actors.Group{} = actor_group) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> soft_delete_policies()
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  defp soft_delete_policies(queryable, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      queryable
      |> Authorizer.for_subject(subject)
      |> soft_delete_policies()
    end
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  defp soft_delete_policies(queryable) do
    {_count, policies} =
      queryable
      |> Policy.Query.delete()
      |> Repo.update_all([])

    {:ok, policies}
  end

  def filter_by_conforming_policies_for_client(policies, %Clients.Client{} = client) do
    Enum.filter(policies, fn policy ->
      policy.conditions
      |> Condition.Evaluator.ensure_conforms(client)
      |> case do
        {:ok, _expires_at} -> true
        {:error, _violated_properties} -> false
      end
    end)
  end

  @infinity ~U[9999-12-31 23:59:59.999999Z]

  def longest_conforming_policy_for_client(policies, client, token_expires_at) do
    policies
    |> Enum.reduce(%{failed: [], succeeded: []}, fn policy, acc ->
      case ensure_client_conforms_policy_conditions(client, policy) do
        {:ok, expires_at} ->
          %{acc | succeeded: [{expires_at, policy} | acc.succeeded]}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          %{acc | failed: acc.failed ++ violated_properties}
      end
    end)
    |> case do
      %{succeeded: [], failed: failed} ->
        {:error, {:forbidden, violated_properties: Enum.uniq(failed)}}

      %{succeeded: succeeded} ->
        {expires_at, policy} =
          succeeded
          |> Enum.max_by(fn {expires_at, _policy} -> expires_at || @infinity end)

        {:ok, policy, min_expires_at(expires_at, token_expires_at)}
    end
  end

  def ensure_client_conforms_policy_conditions(
        %Clients.Client{} = client,
        %__MODULE__.Policy{} = policy
      ) do
    ensure_client_conforms_policy_conditions(client, Cacheable.to_cache(policy))
  end

  def ensure_client_conforms_policy_conditions(
        %Clients.Client{} = client,
        %Cacheable.Policy{} = policy
      ) do
    case Condition.Evaluator.ensure_conforms(policy.conditions, client) do
      {:ok, expires_at} ->
        {:ok, expires_at}

      {:error, violated_properties} ->
        {:error, {:forbidden, violated_properties: violated_properties}}
    end
  end

  defp min_expires_at(nil, nil),
    do: raise("Both policy_expires_at and token_expires_at cannot be nil")

  defp min_expires_at(nil, token_expires_at), do: token_expires_at

  defp min_expires_at(%DateTime{} = policy_expires_at, %DateTime{} = token_expires_at) do
    if DateTime.compare(policy_expires_at, token_expires_at) == :lt do
      policy_expires_at
    else
      token_expires_at
    end
  end

  defp ensure_has_access_to(%Auth.Subject{} = subject, %Policy{} = policy) do
    if subject.account.id == policy.account_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end
