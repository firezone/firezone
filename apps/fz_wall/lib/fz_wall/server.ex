defmodule FzWall.Server do
  @moduledoc """
  Functions for applying firewall rules.
  """

  use GenServer
  import FzWall.CLI

  @process_opts Application.compile_env(:fz_wall, :server_process_opts, [])
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
  def handle_call({:add_rules, rule_spec}, _from, rules) do
    new_rules = add_rules(rule_spec, rules)

    {:reply, :ok, new_rules}
  end

  @impl GenServer
  def handle_call({:delete_rule, rules_spec}, _from, rules) do
    new_rules = delete_rules(rules_spec, rules)
    {:reply, :ok, new_rules}
  end

  @impl GenServer
  def handle_call({:delete_device_rules, {ipv4, nil}}, _from, rules),
    do: delete_device_rules(ipv4, rules)

  @impl GenServer
  def handle_call({:delete_device_rules, {nil, ipv6}}, _from, rules),
    do: delete_device_rules(ipv6, rules)

  @impl GenServer
  def handle_call({:delete_device_rules, {ipv4, ipv6}}, _from, rules) do
    {:reply, :ok, new_rules} = delete_device_rules(ipv4, rules)
    delete_device_rules(ipv6, new_rules)
  end

  @impl GenServer
  def handle_call({:set_rules, fz_http_rules}, _from, _rules) do
    cli().restore(fz_http_rules)
    {:reply, :ok, fz_http_rules}
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

  defp delete_device_rules(source, rules) do
    cli().delete_rules(source)
    # XXX: Consider using MapSet here

    new_rules =
      Enum.reject(rules, fn rule ->
        case rule do
          {src, _, _} -> src == source
          _ -> false
        end
      end)

    {:reply, :ok, new_rules}
  end

  # XXX: For multiple rules it'd be better to have something like [ src1 | src2 | src3 | ...]
  # instead of multiple callings to delete_rule
  defp delete_rules(rules_spec, rules) do
    Enum.reduce(rules_spec, MapSet.new(rules), fn rule_spec, rules_acc ->
      cli().delete_rule(rule_spec)
      MapSet.delete(rules_acc, rule_spec)
    end)
    |> Enum.to_list()
  end

  defp add_rules(rules_spec, rules) do
    Enum.reduce(rules_spec, MapSet.new(rules), fn rule_spec, rules_acc ->
      cli().add_rule(rule_spec)
      MapSet.put(rules_acc, rule_spec)
    end)
    |> Enum.to_list()
  end
end
