defmodule FgHttpWeb.RuleView do
  use FgHttpWeb, :view

  def protocol_options_for_select do
    RuleProtocolEnum.__enum_map__()
  end

  def action_options_for_select do
    RuleActionEnum.__enum_map__()
  end

  def port_number_helper(rule) when is_nil(rule.port_number) do
    "-"
  end

  def port_number_helper(rule), do: rule.port_number

  def status_helper(rule) do
    if rule.enabled do
      "Enabled"
    else
      "Disabled"
    end
  end
end
