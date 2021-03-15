defmodule FgHttpWeb.RuleView do
  use FgHttpWeb, :view

  def action_options_for_select do
    RuleActionEnum.__enum_map__()
  end

  def status_helper(rule) do
    if rule.enabled do
      "Enabled"
    else
      "Disabled"
    end
  end
end
