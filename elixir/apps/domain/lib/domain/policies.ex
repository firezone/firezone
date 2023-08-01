defmodule Domain.Policies do
  alias Domain.{Auth, Repo, Validator}
  alias Domain.Policy
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
      Policy.Query.by_id(id)
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
        Policy.Query.all()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(policies, preload)}
    end
  end

  def create_policy(attrs, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Changeset.create_changeset(attrs, subject)
      |> Repo.insert()
    end
  end

  def update_policy(policy, attrs, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         :ok <- ensure_has_access_to(subject, policy) do
      Policy.Changeset.update_changeset(policy, attrs)
      |> Repo.update()
    end
  end

  def delete_policy(policy, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of, [Authorizer.manage_policies_permission()]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Policy.Changeset.delete_changeset/1)
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
