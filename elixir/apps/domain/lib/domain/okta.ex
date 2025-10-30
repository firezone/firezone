defmodule Domain.Okta do
  alias Domain.{
    Accounts,
    Auth,
    Okta,
    Repo
  }

  def create_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.insert(changeset)
    end
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      %Okta.AuthProvider{}
      |> Okta.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def update_auth_provider(
        %Okta.AuthProvider{} = auth_provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      auth_provider
      |> Okta.AuthProvider.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def update_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.update(changeset)
    end
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.AuthProvider.Query.not_disabled()
      |> Okta.AuthProvider.Query.by_account_id(subject.account.id)
      |> Okta.AuthProvider.Query.by_id(id)
      |> Repo.fetch(Okta.AuthProvider.Query)
    end
  end

  def fetch_auth_provider_by_id(
        %Accounts.Account{} = account,
        id
      ) do
    Okta.AuthProvider.Query.not_disabled()
    |> Okta.AuthProvider.Query.by_account_id(account.id)
    |> Okta.AuthProvider.Query.by_id(id)
    |> Repo.fetch(Okta.AuthProvider.Query)
  end

  def fetch_directory_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.Directory.Query.all()
      |> Okta.Directory.Query.by_account_id(subject.account.id)
      |> Okta.Directory.Query.by_id(id)
      |> Repo.fetch(Okta.Directory.Query)
    end
  end

  def delete_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission),
         {:ok, auth_provider} <- fetch_auth_provider_by_id(id, subject) do
      Repo.delete(auth_provider)
    end
  end

  def all_directories_for_account!(%Accounts.Account{} = account) do
    Okta.Directory.Query.all()
    |> Okta.Directory.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    Okta.AuthProvider.Query.not_disabled()
    |> Okta.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_auth_providers_for_account!(%Accounts.Account{} = account) do
    Okta.AuthProvider.Query.all()
    |> Okta.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end
end
