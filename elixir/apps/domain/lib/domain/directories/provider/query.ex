defmodule Domain.Directories.Provider.Query do
  use Domain, :query
  alias Domain.Accounts

  def all do
    from(provider in Domain.Directories.Provider, as: :providers)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [providers: providers], is_nil(providers.disabled_at))
  end

  def by_id(queryable, id) do
    where(queryable, [providers: providers], providers.id == ^id)
  end

  def by_type(queryable, type) do
    where(queryable, [providers: providers], providers.type == ^type)
  end

  def by_account(queryable, %Accounts.Account{} = account) do
    where(queryable, [providers: providers], providers.account_id == ^account.id)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields do
    [
      {:providers, :asc, :inserted_at},
      {:providers, :asc, :id}
    ]
  end
end
