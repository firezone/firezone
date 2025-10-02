defmodule Domain.Okta do
  alias Domain.{
    Accounts,
    Auth,
    Okta,
    Repo
  }

  def all_enabled_directories_for_account!(%Accounts.Account{} = account) do
    Okta.Directory.Query.not_disabled()
    |> Okta.Directory.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    Okta.AuthProvider.Query.not_disabled()
    |> Okta.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def create_auth_provider(attrs, %Accounts.Account{} = account) do
    Okta.AuthProvider.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def create_directory(attrs, %Accounts.Account{} = account) do
    Okta.Directory.Changeset.create(attrs, account)
    |> Repo.insert()
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
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
end
