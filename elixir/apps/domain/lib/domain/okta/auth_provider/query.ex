defmodule Domain.Okta.AuthProvider.Query do
  use Domain, :query

  def all do
    from(providers in Domain.Okta.AuthProvider, as: :providers)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [providers: providers], not providers.is_disabled)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end

  def by_id(querable, id) do
    where(querable, [providers: providers], providers.id == ^id)
  end

  def by_okta_domain(queryable, okta_domain) do
    where(queryable, [providers: providers], providers.okta_domain == ^okta_domain)
  end
end
