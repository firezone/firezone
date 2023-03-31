defmodule FzHttp.Rules.Rule.Query do
  use FzHttp, :query

  def all do
    from(rules in FzHttp.Rules.Rule, as: :rules)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [rules: rules], rules.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [rules: rules], rules.user_id == ^user_id)
  end

  def by_action(queryable \\ all(), action) do
    where(queryable, [rules: rules], rules.action == ^action)
  end

  def by_empty_port_type(queryable \\ all()) do
    where(queryable, [rules: rules], is_nil(rules.port_type))
  end
end
