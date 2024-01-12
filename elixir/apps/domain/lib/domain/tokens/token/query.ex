defmodule Domain.Tokens.Token.Query do
  use Domain, :query

  def all do
    from(tokens in Domain.Tokens.Token, as: :tokens)
  end

  def not_deleted do
    all()
    |> where([tokens: tokens], is_nil(tokens.deleted_at))
  end

  def not_expired(queryable \\ not_deleted()) do
    where(
      queryable,
      [tokens: tokens],
      tokens.expires_at > ^DateTime.utc_now() or is_nil(tokens.expires_at)
    )
  end

  def expired(queryable \\ not_deleted()) do
    where(queryable, [tokens: tokens], tokens.expires_at <= ^DateTime.utc_now())
  end

  def by_id(queryable \\ not_deleted(), id) do
    where(queryable, [tokens: tokens], tokens.id == ^id)
  end

  def by_type(queryable \\ not_deleted(), type) do
    where(queryable, [tokens: tokens], tokens.type == ^type)
  end

  def by_account_id(queryable \\ not_deleted(), account_id)

  def by_account_id(queryable, nil) do
    where(queryable, [tokens: tokens], is_nil(tokens.account_id))
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [tokens: tokens], tokens.account_id == ^account_id)
  end

  def by_actor_id(queryable \\ not_deleted(), actor_id) do
    where(queryable, [tokens: tokens], tokens.actor_id == ^actor_id)
  end

  def by_relay_group_id(queryable \\ not_deleted(), relay_group_id) do
    where(queryable, [tokens: tokens], tokens.relay_group_id == ^relay_group_id)
  end

  def by_gateway_group_id(queryable \\ not_deleted(), gateway_group_id) do
    where(queryable, [tokens: tokens], tokens.gateway_group_id == ^gateway_group_id)
  end

  def with_joined_account(queryable \\ not_deleted()) do
    with_named_binding(queryable, :account, fn queryable, binding ->
      join(queryable, :inner, [tokens: tokens], account in assoc(tokens, ^binding), as: ^binding)
    end)
  end
end
