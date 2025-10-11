defmodule Domain.Okta do
  alias Domain.{
    Accounts,
    Auth,
    Okta,
    Repo
  }

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

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def create_directory(attrs, %Auth.Subject{} = subject) do
    required_permission = Okta.Authorizer.manage_directories_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Okta.Directory.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_auth_provider_id(
        %Accounts.Account{} = account,
        auth_provider_id
      ) do
    Okta.AuthProvider.Query.not_disabled()
    |> Okta.AuthProvider.Query.by_account_id(account.id)
    |> Okta.AuthProvider.Query.by_auth_provider_id(auth_provider_id)
    |> Repo.fetch(Okta.AuthProvider.Query)
  end
end
