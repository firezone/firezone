defmodule Domain.Email do
  alias Domain.{
    Accounts,
    Auth,
    Email,
    Repo
  }

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Email.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Email.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_for_account(%Accounts.Account{} = account) do
    Email.AuthProvider.Query.not_disabled()
    |> Email.AuthProvider.Query.by_account_id(account.id)
    |> Repo.fetch(Email.AuthProvider.Query)
  end
end
