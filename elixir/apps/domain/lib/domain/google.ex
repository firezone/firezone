defmodule Domain.Google do
  alias Domain.{
    Accounts,
    Auth,
    Google,
    Repo
  }

  def create_oidc_provider(attrs, %Auth.Subject{} = subject) do
    required_permission = Google.Authorizer.manage_oidc_providers_permission()

    with :ok <- Auth.ensure_has_permissions(subject, required_permission) do
      Google.OIDCProvider.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def fetch_oidc_provider_for_account(%Accounts.Account{} = account) do
    Google.OIDCProvider.Query.all()
    |> Google.OIDCProvider.Query.by_account_id(account.id)
    |> Repo.fetch(Google.OIDCProvider.Query)
  end
end
