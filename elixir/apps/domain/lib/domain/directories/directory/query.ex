defmodule Domain.Directories.Directory.Query do
  use Domain, :query

  alias Domain.Directories.Directory

  def all do
    from(directories in Directory, as: :directories)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [directories: directories], directories.account_id == ^account_id)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [directories: directories], directories.id == ^id)
  end

  def by_type(queryable \\ all(), type) do
    where(queryable, [directories: directories], directories.type == ^type)
  end
end
