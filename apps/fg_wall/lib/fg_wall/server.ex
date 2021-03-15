defmodule FgWall.Server do
  @moduledoc """
  Functions for applying firewall rules.

  Startup:
  Clear firewall rules.

  Received events:
  - set_rules: apply rules
  """

  use GenServer
  import FgWall.CLI

  @process_opts Application.compile_env(:fg_wall, :server_process_opts)

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, @process_opts)
  end

  @impl true
  def init(rules) do
    {:ok, rules}
  end

  def handle_call({:add_rule, rule_spec}, rules) do
    cli().add_rule(rule_spec)
    {:reply, :rule_added, rules}
  end

  def handle_call({:delete_rule, rule_spec}, rules) do
    cli().delete_rule(rule_spec)
    {:reply, :rule_deleted, rules}
  end

  def handle_call({:set_rules, fg_http_rules}, rules) do
    cli().restore(fg_http_rules)
    {:reply, :rules_set, rules}
  end
end
