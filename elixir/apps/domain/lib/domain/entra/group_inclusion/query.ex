defmodule Domain.Entra.GroupInclusion.Query do
  use Domain, :query

  alias Domain.Entra.GroupInclusion

  def all do
    from(gi in GroupInclusion)
  end

  def by_directory_id(queryable, directory_id) do
    from(gi in queryable, where: gi.directory_id == ^directory_id)
  end

  def by_account_id(queryable, account_id) do
    from(gi in queryable, where: gi.account_id == ^account_id)
  end
end
