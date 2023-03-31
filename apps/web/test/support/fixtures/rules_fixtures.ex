defmodule FzHttp.RulesFixtures do
  alias FzHttp.UsersFixtures
  alias FzHttp.SubjectFixtures
  alias FzHttp.Rules

  defp rule_attrs(attrs, default) do
    attrs = Enum.into(attrs, default)

    if user = Map.get(attrs, :user) do
      Map.put(attrs, :user_id, user.id)
    else
      attrs
    end
  end

  def ipv4_rule_attrs(attrs \\ %{}) do
    rule_attrs(attrs, %{destination: "10.10.10.0/24"})
  end

  def create_rule(attrs \\ %{}) do
    create_ipv4_rule(attrs)
  end

  def create_ipv4_rule(attrs \\ %{}) do
    attrs = ipv4_rule_attrs(attrs)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        UsersFixtures.create_user_with_role(:admin)
        |> SubjectFixtures.create_subject()
      end)

    {:ok, rule} = Rules.create_rule(attrs, subject)

    rule
  end

  def ipv6_rule_attrs(attrs \\ %{}) do
    rule_attrs(attrs, %{destination: "::/0"})
  end

  def create_ipv6_rule(attrs \\ %{}) do
    attrs = ipv6_rule_attrs(attrs)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        UsersFixtures.create_user_with_role(:admin)
        |> SubjectFixtures.create_subject()
      end)

    {:ok, rule} = Rules.create_rule(attrs, subject)

    rule
  end
end
