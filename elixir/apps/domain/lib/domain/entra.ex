defmodule Domain.Entra do
  alias Domain.{
    Accounts,
    Auth,
    Entra,
    Repo
  }

  def all_enabled_auth_providers_for_account!(%Accounts.Account{} = account) do
    Entra.AuthProvider.Query.not_disabled()
    |> Entra.AuthProvider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def create_auth_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Entra.Authorizer.manage_auth_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Entra.AuthProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_auth_provider_for_account_and_tenant_id(
        %Accounts.Account{} = account,
        tenant_id
      ) do
    Entra.AuthProvider.Query.all()
    |> Entra.AuthProvider.Query.by_account_id(account.id)
    |> Entra.AuthProvider.Query.by_tenant_id(tenant_id)
    |> Repo.fetch(Entra.AuthProvider.Query)
  end
end
