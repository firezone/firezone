defmodule FzWall.CLI.Sandbox do
  @moduledoc """
  Dummy module for working with nftables.
  """

  @default_returned ""

  def setup_table, do: @default_returned
  def setup_chains, do: @default_returned
  def teardown_table, do: @default_returned
  def add_rule(_rule_spec), do: @default_returned
  def delete_rule(_rule_spec), do: @default_returned
  def delete_rules(_rules_spec), do: @default_returned
  def restore(_fz_http_rules), do: @default_returned
  def egress_address, do: "10.0.0.1"
end
