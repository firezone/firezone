defmodule Domain.EmailOTP do
  alias Domain.{
    Accounts,
    Auth,
    EmailOTP,
    Repo
  }

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = EmailOTP.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      EmailOTP.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_id(%Accounts.Account{} = account, auth_provider_id) do
    EmailOTP.AuthProvider.Query.not_disabled()
    |> EmailOTP.AuthProvider.Query.by_account_id(account.id)
    |> EmailOTP.AuthProvider.Query.by_id(auth_provider_id)
    |> Repo.fetch(EmailOTP.AuthProvider.Query)
  end

  def fetch_auth_provider_by_account(%Accounts.Account{} = account) do
    EmailOTP.AuthProvider.Query.not_disabled()
    |> EmailOTP.AuthProvider.Query.by_account_id(account.id)
    |> Repo.fetch(EmailOTP.AuthProvider.Query)
  end
end
