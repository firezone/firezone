defmodule Domain.OIDC do
  alias Domain.{
    Accounts,
    Auth,
    OIDC,
    Repo
  }

  def create_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.insert(changeset)
    end
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      %OIDC.AuthProvider{}
      |> OIDC.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def update_auth_provider(
        %OIDC.AuthProvider{} = auth_provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      auth_provider
      |> OIDC.AuthProvider.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def update_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.update(changeset)
    end
  end

  def fetch_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      OIDC.AuthProvider.Query.not_disabled()
      |> OIDC.AuthProvider.Query.by_account_id(subject.account.id)
      |> OIDC.AuthProvider.Query.by_id(id)
      |> Repo.fetch(OIDC.AuthProvider.Query)
    end
  end

  def fetch_auth_provider_by_id(
        %Accounts.Account{} = account,
        id
      ) do
    OIDC.AuthProvider.Query.not_disabled()
    |> OIDC.AuthProvider.Query.by_account_id(account.id)
    |> OIDC.AuthProvider.Query.by_id(id)
    |> Repo.fetch(OIDC.AuthProvider.Query)
  end

  def delete_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission),
         {:ok, auth_provider} <- fetch_auth_provider_by_id(id, subject) do
      Repo.delete(auth_provider)
    end
  end

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    OIDC.AuthProvider.Query.not_disabled()
    |> OIDC.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_auth_providers_for_account!(%Accounts.Account{} = account) do
    OIDC.AuthProvider.Query.all()
    |> OIDC.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end
end
