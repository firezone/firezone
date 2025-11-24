defmodule Domain.Policies do
  alias Domain.{Repo, Safe}
  alias Domain.{Auth, Cache.Cacheable, Clients}
  alias Domain.Policies.{Policy, Condition}
  require Logger

  def fetch_policy_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Policy.Query.all()
        |> Policy.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        policy -> {:ok, policy}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def list_policies(%Auth.Subject{} = subject, opts \\ []) do
    Policy.Query.all()
    |> Safe.scoped(subject)
    |> Safe.list(Policy.Query, opts)
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
    changeset = Policy.Changeset.create(attrs, subject)

    Safe.scoped(changeset, subject)
    |> Safe.insert()
  end

  def change_policy(%Policy{} = policy, attrs) do
    Policy.Changeset.update(policy, attrs)
  end

  def update_policy(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    changeset = Policy.Changeset.update(policy, attrs)

    Safe.scoped(changeset, subject)
    |> Safe.update()
  end

  def disable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    changeset = Policy.Changeset.disable(policy, subject)

    Safe.scoped(changeset, subject)
    |> Safe.update()
  end

  def enable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    changeset = Policy.Changeset.enable(policy)

    Safe.scoped(changeset, subject)
    |> Safe.update()
  end

  def delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    Safe.scoped(policy, subject)
    |> Safe.delete()
  end

  def filter_by_conforming_policies_for_client(
        policies,
        %Clients.Client{} = client,
        auth_provider_id
      ) do
    Enum.filter(policies, fn policy ->
      policy.conditions
      |> Condition.Evaluator.ensure_conforms(client, auth_provider_id)
      |> case do
        {:ok, _expires_at} -> true
        {:error, _violated_properties} -> false
      end
    end)
  end

  @infinity ~U[9999-12-31 23:59:59.999999Z]

  def longest_conforming_policy_for_client(policies, client, auth_provider_id, expires_at) do
    policies
    |> Enum.reduce(%{failed: [], succeeded: []}, fn policy, acc ->
      case ensure_client_conforms_policy_conditions(policy, client, auth_provider_id) do
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
        {condition_expires_at, policy} =
          succeeded |> Enum.max_by(fn {exp, _policy} -> exp || @infinity end)

        {:ok, policy, min_expires_at(condition_expires_at, expires_at)}
    end
  end

  defp ensure_client_conforms_policy_conditions(
         %__MODULE__.Policy{} = policy,
         %Clients.Client{} = client,
         auth_provider_id
       ) do
    ensure_client_conforms_policy_conditions(Cacheable.to_cache(policy), client, auth_provider_id)
  end

  defp ensure_client_conforms_policy_conditions(
         %Cacheable.Policy{} = policy,
         %Clients.Client{} = client,
         auth_provider_id
       ) do
    case Condition.Evaluator.ensure_conforms(policy.conditions, client, auth_provider_id) do
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
end
