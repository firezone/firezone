defmodule FzWall.Server do
  @moduledoc """
  Functions for applying firewall rules.

  Startup:
  Clear firewall rules.

  Received events:
  - set_rules: apply rules
  """

  use GenServer
  import FzWall.CLI

  @process_opts Application.compile_env(:fz_wall, :server_process_opts)

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, @process_opts)
  end

  @impl true
  def init(rules) do
    {:ok, rules}
  end

  @impl true
  def handle_call({:add_rule, rule_spec}, _from, rules) do
    cli().add_rule(rule_spec)
    {:reply, :ok, rules}
  end

  @impl true
  def handle_call({:delete_rule, rule_spec}, _from, rules) do
    cli().delete_rule(rule_spec)
    {:reply, :ok, rules}
  end

  @impl true
  def handle_call({:set_rules, fz_http_rules}, _from, rules) do
    cli().restore(fz_http_rules)
    {:reply, :ok, rules}
  end
end
