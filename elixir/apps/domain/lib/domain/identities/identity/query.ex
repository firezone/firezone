defmodule Domain.Identities.Identity.Query do
  use Domain, :query

  def all do
    from(identities in Domain.Identities.Identity, as: :identities)
  end

  def not_deleted(queryable \\ all()) do
    where(queryable, [identities: identities], is_nil(identities.deleted_at))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [identities: identities], identities.account_id == ^account_id)
  end

  def by_directory_id(queryable, directory_id) do
    where(queryable, [identities: identities], identities.directory_id == ^directory_id)
  end

  def by_provider_identifier(queryable, provider_identifier) do
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier == ^provider_identifier
    )
  end
end
