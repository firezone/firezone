defmodule Domain.Google.Directory.Query do
  use Domain, :query

  def all do
    from(directories in Domain.Google.Directory, as: :directories)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [directories: directories], directories.account_id == ^account_id)
  end

  def by_hosted_domain(queryable, hosted_domain) do
    where(queryable, [directories: directories], directories.hosted_domain == ^hosted_domain)
  end
end
