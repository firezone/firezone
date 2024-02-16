defmodule Domain.Accounts.Account.Query do
  use Domain, :query
  alias Domain.Validator

  def all do
    from(account in Domain.Accounts.Account, as: :account)
  end

  def not_deleted(queryable \\ all()) do
    where(queryable, [account: account], is_nil(account.deleted_at))
  end

  def by_id(queryable \\ not_deleted(), id)

  def by_id(queryable, {:in, ids}) do
    where(queryable, [account: account], account.id in ^ids)
  end

  def by_id(queryable, id) do
    where(queryable, [account: account], account.id == ^id)
  end

  def by_stripe_customer_id(queryable, customer_id) do
    where(
      queryable,
      [account: account],
      fragment("?->'stripe'->>'customer_id' = ?", account.metadata, ^customer_id)
    )
  end

  def by_slug(queryable \\ not_deleted(), slug) do
    where(queryable, [account: account], account.slug == ^slug)
  end

  def by_id_or_slug(queryable \\ not_deleted(), id_or_slug) do
    if Validator.valid_uuid?(id_or_slug) do
      by_id(queryable, id_or_slug)
    else
      by_slug(queryable, id_or_slug)
    end
  end
end
