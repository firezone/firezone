defmodule Domain.Directories.Provider.Query do
  use Domain, :query

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
end
