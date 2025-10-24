defmodule Domain.Entra.Directory.Query do
  use Domain, :query

  def all do
    from(directories in Domain.Entra.Directory, as: :directories)
  end

  def not_disabled(queryable \\ all()) do
    where(queryable, [directories: directories], is_nil(directories.disabled_at))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [directories: directories], directories.account_id == ^account_id)
  end

  def by_tenant_id(queryable, tenant_id) do
    where(queryable, [directories: directories], directories.tenant_id == ^tenant_id)
  end
end
