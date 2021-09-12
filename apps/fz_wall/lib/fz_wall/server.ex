defmodule FzWall.Server do
  @moduledoc """
  Functions for applying firewall rules.
  """

  use GenServer
  import FzWall.CLI

  @process_opts Application.compile_env(:fz_wall, :server_process_opts)
  @init_timeout 1_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, @process_opts)
  end

  @impl GenServer
  def init(_rules) do
    cli().teardown_table()
    cli().setup_table()
    cli().setup_chains()
    {:ok, existing_rules} = GenServer.call(http_pid(), :load_rules, @init_timeout)
    cli().restore(existing_rules)
    {:ok, existing_rules}
  end

  @impl GenServer
  def handle_call({:add_rule, rule_spec}, _from, rules) do
    cli().add_rule(rule_spec)
    {:reply, :ok, rules}
  end

  @impl GenServer
  def handle_call({:delete_rule, rule_spec}, _from, rules) do
    cli().delete_rule(rule_spec)
    {:reply, :ok, rules}
  end

  @impl GenServer
  def handle_call({:set_rules, fz_http_rules}, _from, rules) do
    cli().restore(fz_http_rules)
    {:reply, :ok, rules}
  end

  # XXX: Set up NAT and Masquerade and load existing rules with nftables here
  @impl GenServer
  def handle_call(:setup, _from, rules) do
    {:reply, :ok, rules}
  end

  # XXX: Tear down NAT and Masquerade and drop rules here
  @impl GenServer
  def handle_call(:teardown, _from, rules) do
    {:reply, :ok, rules}
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end
end
