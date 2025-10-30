defmodule Domain.Entra do
  alias Domain.{
    Accounts,
    Auth,
    Entra,
    Repo
  }

  def create_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.insert(changeset)
    end
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      %Entra.AuthProvider{}
      |> Entra.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def update_auth_provider(
        %Entra.AuthProvider{} = auth_provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      auth_provider
      |> Entra.AuthProvider.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def update_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.update(changeset)
    end
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Entra.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Entra.AuthProvider.Query.not_disabled()
      |> Entra.AuthProvider.Query.by_account_id(subject.account.id)
      |> Entra.AuthProvider.Query.by_id(id)
      |> Repo.fetch(Entra.AuthProvider.Query)
    end
  end

  def fetch_auth_provider_by_id(
        %Accounts.Account{} = account,
        id
      ) do
    Entra.AuthProvider.Query.not_disabled()
    |> Entra.AuthProvider.Query.by_account_id(account.id)
    |> Entra.AuthProvider.Query.by_id(id)
    |> Repo.fetch(Entra.AuthProvider.Query)
  end

  def fetch_directory_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Entra.Directory.Query.all()
      |> Entra.Directory.Query.by_account_id(subject.account.id)
      |> Entra.Directory.Query.by_id(id)
      |> Repo.fetch(Entra.Directory.Query)
    end
  end

  def delete_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission),
         {:ok, auth_provider} <- fetch_auth_provider_by_id(id, subject) do
      Repo.delete(auth_provider)
    end
  end

  def all_directories_for_account!(%Accounts.Account{} = account) do
    Entra.Directory.Query.all()
    |> Entra.Directory.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    Entra.AuthProvider.Query.not_disabled()
    |> Entra.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_auth_providers_for_account!(%Accounts.Account{} = account) do
    Entra.AuthProvider.Query.all()
    |> Entra.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end
end
