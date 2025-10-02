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
      Userpass.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_for_account(%Accounts.Account{} = account) do
    Userpass.AuthProvider.Query.not_disabled()
    |> Userpass.AuthProvider.Query.by_account_id(account.id)
    |> Repo.fetch(Userpass.AuthProvider.Query)
  end
end
