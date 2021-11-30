defmodule FzHttp.RulesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Rules` context.
  """

  alias FzHttp.Rules

  def rule4(attrs \\ %{}) do
    rule(attrs)
  end

  def rule6(attrs \\ %{}) do
    rule(Map.merge(attrs, %{destination: "::/0"}))
  end

  def rule(attrs \\ %{}) do
    default_attrs = %{
      destination: "10.10.10.0/24"
    }

    {:ok, rule} = Rules.create_rule(Map.merge(default_attrs, attrs))
    rule
  end
end
