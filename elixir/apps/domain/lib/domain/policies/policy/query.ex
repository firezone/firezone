defmodule Domain.Policies.Policy.Query do
  use Domain, :query

  def all do
    from(policies in Domain.Policies.Policy, as: :policies)
    |> where([policies: policies], is_nil(policies.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [policies: policies], policies.id == ^id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [policies: policies], policies.account_id == ^account_id)
  end
end
