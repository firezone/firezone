defmodule Domain.Userpass do
  alias Domain.{
    Accounts,
    Auth,
    Userpass,
    Repo
  }

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Userpass.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Userpass.AuthProvider.Changeset.create(%Userpass.AuthProvider{}, attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_id(auth_provider_id, %Auth.Subject{} = subject) do
    required_permission = Userpass.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Userpass.AuthProvider.Query.not_disabled()
      |> Userpass.AuthProvider.Query.by_account_id(subject.account.id)
      |> Userpass.AuthProvider.Query.by_id(auth_provider_id)
      |> Repo.fetch(Userpass.AuthProvider.Query)
    end
  end

  def fetch_auth_provider_by_id(%Accounts.Account{} = account, auth_provider_id) do
    Userpass.AuthProvider.Query.not_disabled()
    |> Userpass.AuthProvider.Query.by_account_id(account.id)
    |> Userpass.AuthProvider.Query.by_id(auth_provider_id)
    |> Repo.fetch(Userpass.AuthProvider.Query)
  end

  def fetch_auth_provider_by_account(%Accounts.Account{} = account) do
    Userpass.AuthProvider.Query.not_disabled()
    |> Userpass.AuthProvider.Query.by_account_id(account.id)
    |> Repo.fetch(Userpass.AuthProvider.Query)
  end

  def update_auth_provider(%Ecto.Changeset{} = changeset, %Auth.Subject{} = subject) do
    required_permission = Userpass.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Repo.update(changeset)
    end
  end

  def all_auth_providers_for_account!(%Accounts.Account{} = account) do
    Userpass.AuthProvider.Query.all()
    |> Userpass.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end
end
