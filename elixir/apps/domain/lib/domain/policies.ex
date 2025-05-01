defmodule Domain.Policies do
  alias Domain.Repo
  alias Domain.{Auth, Actors, Clients, Resources}
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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {0, nil} ->
          {:error, "unable to delete"}

        {1, nil} ->
          :ok

        error ->
          Logger.error("Unknown error while deleting policy",
            account_id: policy.account_id,
            policy_id: policy.id,
            reason: inspect(error)
          )

          {:error, "unknown error"}
      end
    end
  end

  def delete_policies_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.all()
      |> Policy.Query.by_resource_id(resource.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {0, nil} ->
          {:error, "unable to delete policies for resource"}

        {_n, nil} ->
          :ok

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

  def delete_policies_for(%Actors.Group{} = actor_group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.all()
      |> Policy.Query.by_actor_group_id(actor_group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {0, nil} ->
          {:error, "unable to delete policies for group"}

        {_n, nil} ->
          :ok

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

  def delete_policies_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.all()
      |> Policy.Query.by_actor_group_provider_id(provider.id)
      |> Authorizer.for_subject(subject)
      |> Repo.delete_all()
      |> case do
        {0, nil} ->
          {:error, "unable to delete policies for provider"}

        {_n, nil} ->
          :ok

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

  def delete_policies_for(%Actors.Group{} = actor_group) do
    Policy.Query.all()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> Repo.delete_all()
    |> case do
      {0, nil} ->
        {:error, "unable to delete policies for group"}

      {_n, nil} ->
        :ok

      error ->
        Logger.error("Unknown error while deleting policies for group",
          account_id: actor_group.account_id,
          group_id: actor_group.id,
          reason: inspect(error)
        )

        {:error, "unknown error deleting policies for resource"}
    end
  end

  def soft_delete_policies_for(%Resources.Resource{} = resource, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_resource_id(resource.id)
    |> soft_delete_policies(subject)
  end

  def soft_delete_policies_for(%Actors.Group{} = actor_group, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> soft_delete_policies(subject)
  end

  def soft_delete_policies_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_provider_id(provider.id)
    |> soft_delete_policies(subject)
  end

  def soft_delete_policies_for(%Actors.Group{} = actor_group) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_actor_group_id(actor_group.id)
    |> soft_delete_policies()
  end

  defp soft_delete_policies(queryable, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      queryable
      |> Authorizer.for_subject(subject)
      |> soft_delete_policies()
    end
  end

  defp soft_delete_policies(queryable) do
    {_count, policies} =
      queryable
      |> Policy.Query.delete()
      |> Repo.update_all([])

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
end
