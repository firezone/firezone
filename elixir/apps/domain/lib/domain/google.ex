defmodule Domain.Google do
  alias Domain.{
    Accounts,
    Auth,
    Google,
    Repo
  }

  def all_enabled_directories_for_account!(%Accounts.Account{} = account) do
    Google.Directory.Query.not_disabled()
    |> Google.Directory.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    Google.AuthProvider.Query.not_disabled()
    |> Google.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def create_auth_provider(attrs, %Accounts.Account{} = account) do
    Google.AuthProvider.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def create_directory(attrs, %Accounts.Account{} = account) do
    Google.Directory.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_directory_by_directory_id(%Accounts.Account{} = account, directory_id) do
    Google.Directory.Query.all()
    |> Google.Directory.Query.by_account_id(account.id)
    |> Google.Directory.Query.by_directory_id(directory_id)
    |> Repo.fetch(Google.Directory.Query)
  end

  def fetch_auth_provider_for_account_and_hosted_domain(
        %Accounts.Account{} = account,
        hosted_domain
      ) do
    Google.AuthProvider.Query.all()
    |> Google.AuthProvider.Query.by_account_id(account.id)
    |> Google.AuthProvider.Query.by_hosted_domain(hosted_domain)
    |> Repo.fetch(Google.AuthProvider.Query)
  end
end
