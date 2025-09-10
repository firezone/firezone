defmodule Domain.Entra.Directory.Query do
  use Domain, :query

  alias Domain.Entra.Directory

  def all do
    from(d in Directory)
  end

  def not_disabled(queryable \\ all()) do
    from(d in queryable, where: is_nil(d.disabled_at))
  end

  def by_id(queryable, id) do
    from(d in queryable, where: d.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    from(d in queryable, where: d.account_id == ^account_id)
  end

  def for_sync(queryable) do
    from(d in queryable, select: [:id])
  end

  def with_preloads_for_sync(queryable) do
    from(d in queryable,
      preload: [
        :auth_provider,
        :account,
        # entra_group_inclusions has a composite primary key, so we need an efficient way to query by both account_id
        # and directory_id for preloading
        group_inclusions:
          ^from(gi in Domain.Entra.GroupInclusion,
            where:
              gi.account_id == parent_as(:directory).account_id and
                gi.entra_directory_id == parent_as(:directory).id
          )
      ]
    )
  end
end
