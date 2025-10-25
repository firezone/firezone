defmodule Domain.Google do
  alias Domain.{
    Accounts,
    Auth,
    Google,
    Repo
  }

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.AuthProvider.Query.not_disabled()
      |> Google.AuthProvider.Query.by_account_id(subject.account.id)
      |> Google.AuthProvider.Query.by_id(id)
      |> Repo.fetch(Google.AuthProvider.Query)
    end
  end

  def fetch_auth_provider_by_id(
        %Accounts.Account{} = account,
        id
      ) do
    Google.AuthProvider.Query.not_disabled()
    |> Google.AuthProvider.Query.by_account_id(account.id)
    |> Google.AuthProvider.Query.by_id(id)
    |> Repo.fetch(Google.AuthProvider.Query)
  end

  def fetch_directory_by_id(id, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.Directory.Query.all()
      |> Google.Directory.Query.by_account_id(subject.account.id)
      |> Google.Directory.Query.by_id(id)
      |> Repo.fetch(Google.Directory.Query)
    end
  end

  def update_auth_provider(
        %Google.AuthProvider{} = auth_provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    required_permission = Google.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      auth_provider
      |> Google.AuthProvider.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def update_directory(%Google.Directory{} = directory, attrs, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      directory
      |> Google.Directory.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def all_directories_for_account!(%Accounts.Account{} = account) do
    Google.Directory.Query.all()
    |> Google.Directory.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    Google.AuthProvider.Query.not_disabled()
    |> Google.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_auth_providers_for_account!(%Accounts.Account{} = account) do
    Google.AuthProvider.Query.all()
    |> Google.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end
end
