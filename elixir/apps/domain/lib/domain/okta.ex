defmodule Domain.Okta do
  alias Domain.{
    Accounts,
    Auth,
    Okta,
    Repo
  }

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

  def fetch_auth_provider_for_account_and_org_domain(
        %Accounts.Account{} = account,
        org_domain
      ) do
    Okta.AuthProvider.Query.all()
    |> Okta.AuthProvider.Query.by_account_id(account.id)
    |> Okta.AuthProvider.Query.by_org_domain(org_domain)
    |> Repo.fetch(Okta.AuthProvider.Query)
  end
end
