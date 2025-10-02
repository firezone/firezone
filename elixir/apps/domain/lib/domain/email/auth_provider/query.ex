defmodule Domain.Email.AuthProvider.Query do
  use Domain, :query

  def all do
    from(providers in Domain.Email.AuthProvider, as: :providers)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [providers: providers], is_nil(providers.disabled_at))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [providers: providers], providers.account_id == ^account_id)
  end
end
