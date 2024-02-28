defmodule Domain.Accounts.Account.Query do
  use Domain, :query
  alias Domain.Validator

  def all do
    from(accounts in Domain.Accounts.Account, as: :accounts)
  end

  def not_deleted(queryable \\ all()) do
    where(queryable, [accounts: accounts], is_nil(accounts.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [accounts: accounts], is_nil(accounts.disabled_at))
  end

  def by_id(queryable \\ not_deleted(), id)

  def by_id(queryable, {:in, ids}) do
    where(queryable, [accounts: accounts], accounts.id in ^ids)
  end

  def by_id(queryable, id) do
    where(queryable, [accounts: accounts], accounts.id == ^id)
  end

  def by_stripe_customer_id(queryable, customer_id) do
    where(
      queryable,
      [accounts: accounts],
      fragment("?->'stripe'->>'customer_id' = ?", accounts.metadata, ^customer_id)
    )
  end

  def by_slug(queryable \\ not_deleted(), slug) do
    where(queryable, [accounts: accounts], accounts.slug == ^slug)
  end

  def by_id_or_slug(queryable \\ not_deleted(), id_or_slug) do
    if Validator.valid_uuid?(id_or_slug) do
      by_id(queryable, id_or_slug)
    else
      by_slug(queryable, id_or_slug)
    end
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:accounts, :asc, :inserted_at},
      {:accounts, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads do
    [
      clients: {Domain.Clients.Client.Query.not_deleted(), Domain.Clients.Client.Query.preloads()}
    ]
  end
end
