defmodule FzWall.CLI.Sandbox do
  @moduledoc """
  Dummy module for working with iptables.
  """

  @default_returned ""

  def add_rule(_rule_spec), do: @default_returned
  def delete_rule(_rule_spec), do: @default_returned
  def restore(_fz_http_rules), do: @default_returned
end
