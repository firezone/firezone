defmodule Domain.Google.OIDCProvider.Query do
  use Domain, :query

  def all do
    from(providers in Domain.Google.OIDCProvider, as: :providers)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end

  def by_hosted_domain(queryable, hosted_domain) do
    where(queryable, [providers: providers], providers.hosted_domain == ^hosted_domain)
  end
end
