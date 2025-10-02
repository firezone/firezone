defmodule Domain.OIDC do
  alias Domain.{
    Accounts,
    Auth,
    OIDC,
    Repo
  }

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    OIDC.AuthProvider.Query.not_disabled()
    |> OIDC.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = OIDC.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      OIDC.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_by_id(
        %Accounts.Account{} = account,
        id
      ) do
    OIDC.AuthProvider.Query.not_disabled()
    |> OIDC.AuthProvider.Query.by_account_id(account.id)
    |> OIDC.AuthProvider.Query.by_id(id)
    |> Repo.fetch(OIDC.AuthProvider.Query)
  end
end
