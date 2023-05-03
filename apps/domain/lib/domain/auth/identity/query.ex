defmodule Domain.Auth.Identity.Query do
  use Domain, :query

  def all do
    from(identity in Domain.Auth.Identity, as: :identity)
    |> where([identity: identity], is_nil(identity.deleted_at))
  end

  def by_id(queryable \\ all(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [identity: identity], identity.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [identity: identity], identity.id == ^id)
  end

  def by_adapter(queryable \\ all(), adapter) do
    where(queryable, [identity: identity], identity.adapter == ^adapter)
  end

  def by_provider_identifier(queryable \\ all(), provider_identifier) do
    where(queryable, [identity: identity], identity.provider_identifier == ^provider_identifier)
  end

  def where_sign_in_token_is_not_expired(queryable \\ all()) do
    queryable
    |> where(
      [identity: identity],
      datetime_add(identity.sign_in_token_created_at, 1, "hour") >= fragment("NOW()")
    )
  end

  def with_assoc(queryable \\ all(), assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, :left, [identity: identity], a in assoc(identity, ^binding), as: ^binding)
    end)
  end
end
