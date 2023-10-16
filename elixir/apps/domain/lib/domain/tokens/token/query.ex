defmodule Domain.Tokens.Token.Query do
  use Domain, :query

  def all do
    from(tokens in Domain.Tokens.Token, as: :tokens)
    |> where([tokens: tokens], is_nil(tokens.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [tokens: tokens], tokens.id == ^id)
  end

  def by_context(queryable \\ all(), context) do
    where(queryable, [tokens: tokens], tokens.context == ^context)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [tokens: tokens], tokens.account_id == ^account_id)
  end

  def not_expired(queryable \\ all()) do
    where(queryable, [tokens: tokens], tokens.expires_at > ^DateTime.utc_now())
  end
end
