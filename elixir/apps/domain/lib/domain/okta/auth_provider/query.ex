defmodule Domain.Okta.AuthProvider.Query do
  use Domain, :query

  def all do
    from(providers in Domain.Okta.AuthProvider, as: :providers)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [providers: providers], is_nil(providers.disabled_at))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end

  def by_directory_id(queryable, directory_id) do
    where(queryable, [providers: providers], providers.directory_id == ^directory_id)
  end

  def by_org_domain(queryable, org_domain) do
    where(queryable, [providers: providers], providers.org_domain == ^org_domain)
  end
end
