defmodule Domain.Firezone.Directory.Query do
  use Domain, :query

  def all do
    from(directories in Domain.Firezone.Directory, as: :directories)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [directories: directories], directories.account_id == ^account_id)
  end

  def by_id(queryable, id) do
    where(queryable, [directories: directories], directories.id == ^id)
  end
end
