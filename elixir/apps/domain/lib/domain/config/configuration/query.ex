defmodule Domain.Config.Configuration.Query do
  use Domain, :query

  def all do
    from(configurations in Domain.Config.Configuration, as: :configurations)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [configurations: configurations], configurations.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [configurations: configurations], configurations.account_id == ^account_id)
  end
end
