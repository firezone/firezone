defmodule FzHttp.ApiTokens.ApiToken.Query do
  use FzHttp, :query

  def all do
    from(api_tokens in FzHttp.ApiTokens.ApiToken, as: :api_tokens)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [api_tokens: api_tokens], api_tokens.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [api_tokens: api_tokens], api_tokens.user_id == ^user_id)
  end

  def not_expired(queryable \\ all()) do
    where(queryable, [api_tokens: api_tokens], api_tokens.expires_at >= fragment("NOW()"))
  end
end
