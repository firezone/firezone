defmodule Web.JSON.RuleView do
  @moduledoc """
  Handles JSON rendering of Rule records.
  """
  use Web, :view

  def render("index.json", %{rules: rules}) do
    %{data: render_many(rules, __MODULE__, "rule.json")}
  end

  def render("show.json", %{rule: rule}) do
    %{data: render_one(rule, __MODULE__, "rule.json")}
  end

  @keys_to_render ~w[
    id
    destination
    action
    port_type
    port_range
    user_id
    inserted_at
    updated_at
  ]a
  def render("rule.json", %{rule: rule}) do
    Map.take(rule, @keys_to_render)
  end
end
