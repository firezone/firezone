defmodule Domain.Tokens.Token.Query do
  use Domain, :query

  def all do
    from(tokens in Domain.Tokens.Token, as: :tokens)
  end

  def not_expired(queryable) do
    where(
      queryable,
      [tokens: tokens],
      tokens.expires_at > ^DateTime.utc_now() or is_nil(tokens.expires_at)
    )
  end

  def expired(queryable) do
    where(queryable, [tokens: tokens], tokens.expires_at <= ^DateTime.utc_now())
  end

  def expires_in(queryable, value, unit) do
    duration = Duration.new!([{unit, value}])

    where(
      queryable,
      [tokens: tokens],
      not is_nil(tokens.expires_at) and
        fragment(
          "timezone('UTC', NOW()) + '5 seconds'::interval < ? AND ? < timezone('UTC', NOW()) + ?::interval",
          tokens.expires_at,
          tokens.expires_at,
          ^duration
        )
    )
  end

  def by_id(queryable, id) do
    where(queryable, [tokens: tokens], tokens.id == ^id)
  end

  def by_type(queryable, type) do
    where(queryable, [tokens: tokens], tokens.type == ^type)
  end

  def by_account_id(queryable, account_id)

  def by_account_id(queryable, nil) do
    where(queryable, [tokens: tokens], is_nil(tokens.account_id))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [tokens: tokens], tokens.account_id == ^account_id)
  end

  def by_actor_id(queryable, actor_id) do
    where(queryable, [tokens: tokens], tokens.actor_id == ^actor_id)
  end

  def by_site_id(queryable, site_id) do
    where(queryable, [tokens: tokens], tokens.site_id == ^site_id)
  end

  def with_joined_account(queryable) do
    with_named_binding(queryable, :account, fn queryable, binding ->
      join(queryable, :inner, [tokens: tokens], account in assoc(tokens, ^binding), as: ^binding)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:tokens, :asc, :inserted_at},
      {:tokens, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :type,
        type: :string,
        values: [
          {"API Client", "api_client"},
          {"Browser", "browser"},
          {"Client", "client"},
          {"Email", "email"},
          {"Site", "site"},
          {"Relay", "relay"}
        ],
        fun: &filter_by_type/2
      }
    ]

  def filter_by_type(queryable, type) do
    {queryable, dynamic([tokens: tokens], tokens.type == ^type)}
  end
end
