defmodule Domain.Accounts.Account.Query do
  use Domain, :query

  def all do
    from(accounts in Domain.Accounts.Account, as: :accounts)
  end

  def not_deleted(queryable \\ all()) do
    where(queryable, [accounts: accounts], is_nil(accounts.deleted_at))
  end

  def disabled(queryable \\ all()) do
    where(queryable, [accounts: accounts], not is_nil(accounts.disabled_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [accounts: accounts], is_nil(accounts.disabled_at))
  end

  def by_id(queryable, id)

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

  def by_stripe_product_name(queryable, account_type) do
    where(
      queryable,
      [accounts: accounts],
      fragment("?->'stripe'->>'product_name' = ?", accounts.metadata, ^account_type)
    )
  end

  def by_slug(queryable, slug) do
    where(queryable, [accounts: accounts], accounts.slug == ^slug)
  end

  def by_id_or_slug(queryable, id_or_slug) do
    if Domain.Repo.valid_uuid?(id_or_slug) do
      by_id(queryable, id_or_slug)
    else
      by_slug(queryable, id_or_slug)
    end
  end

  def by_notification_enabled(queryable, notification) do
    where(
      queryable,
      [accounts: accounts],
      fragment(
        "(?->'notifications'->?->>'enabled') = 'true'",
        accounts.config,
        ^notification
      )
    )
  end

  def by_notification_last_notified(queryable, notification, hours) do
    interval = Duration.new!(hour: hours)

    where(
      queryable,
      [accounts: accounts],
      fragment(
        "(?->'notifications'->?->>'last_notified')::timestamp < timezone('UTC', NOW()) - ?::interval",
        accounts.config,
        ^notification,
        ^interval
      ) or
        fragment(
          "(?->'notifications'->?->>'last_notified') IS NULL",
          accounts.config,
          ^notification
        )
    )
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:accounts, :asc, :inserted_at},
      {:accounts, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads,
    do: [
      clients: {Domain.Clients.Client.Query.not_deleted(), Domain.Clients.Client.Query.preloads()}
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :slug,
        title: "Slug",
        type: :string,
        fun: &filter_by_slug_contains/2
      },
      %Domain.Repo.Filter{
        name: :name,
        title: "Name",
        type: :string,
        fun: &filter_by_name_fts/2
      },
      %Domain.Repo.Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        values: [
          {"enabled", "Enabled"},
          {"disabled", "Disabled"}
        ],
        fun: &filter_by_status/2
      }
    ]

  def filter_by_slug_contains(queryable, slug) do
    {queryable, dynamic([accounts: accounts], ilike(accounts.slug, ^"%#{slug}%"))}
  end

  def filter_by_name_fts(queryable, name) do
    {queryable, dynamic([accounts: accounts], fulltext_search(accounts.name, ^name))}
  end

  def filter_by_status(queryable, "enabled") do
    {queryable, dynamic([accounts: accounts], is_nil(accounts.disabled_at))}
  end

  def filter_by_status(queryable, "disabled") do
    {queryable, dynamic([accounts: accounts], not is_nil(accounts.disabled_at))}
  end
end
