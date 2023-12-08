defmodule Domain.Policies do
  alias Domain.{Repo, Validator}
  alias Domain.Auth
  alias Domain.Policies.{Authorizer, Policy}

  def fetch_policy_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    required_permissions =
      {:one_of,
       [
         Authorizer.manage_policies_permission(),
         Authorizer.view_available_policies_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Policy.Query.all()
      |> Policy.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, policy} -> {:ok, Repo.preload(policy, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_policies(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    required_permissions =
      {:one_of,
       [
         Authorizer.manage_policies_permission(),
         Authorizer.view_available_policies_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      {:ok, policies} =
        Policy.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(policies, preload)}
    end
  end

  def create_policy(attrs, %Auth.Subject{} = subject) do
    required_permissions = {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def update_policy(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    required_permissions = {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         :ok <- ensure_has_access_to(subject, policy) do
      Policy.Changeset.update(policy, attrs)
      |> Repo.update()
    end
  end

  def disable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Policy.Changeset.disable(&1, subject))
    end
  end

  def enable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Policy.Changeset.enable/1)
    end
  end

  def delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    required_permissions = {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Policy.Changeset.delete/1)
    end
  end

  def new_policy(attrs, %Auth.Subject{} = subject) do
    Policy.Changeset.create(attrs, subject)
  end

  def ensure_has_access_to(%Auth.Subject{} = subject, %Policy{} = policy) do
    if subject.account.id == policy.account_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end
