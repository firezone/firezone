defmodule FzWall.Server do
  @moduledoc """
  Functions for applying firewall rules.
  """
  use GenServer
  import FzWall.CLI

  @init_timeout 1_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: {:global, :fz_wall_server})
  end

  @impl GenServer
  def init(_rules) do
    cli().setup_firewall()
    {:ok, settings} = GenServer.call(http_pid(), :load_settings, @init_timeout)
    cli().restore(settings)
    {:ok, settings}
  end

  @impl GenServer
  def handle_call({:add_rule, rule}, _from, %{rules: existing_rules} = state) do
    new_rules = add_rule(rule, existing_rules)

    {:reply, :ok, %{state | rules: new_rules}}
  end

  @impl GenServer
  def handle_call({:delete_rule, rule}, _from, %{rules: existing_rules} = state) do
    new_rules = delete_rule(rule, existing_rules)

    {:reply, :ok, %{state | rules: new_rules}}
  end

  @impl GenServer
  def handle_call({:add_device, device}, _from, %{devices: existing_devices} = state) do
    new_devices = add_device(device, existing_devices)

    {:reply, :ok, %{state | devices: new_devices}}
  end

  @impl GenServer
  def handle_call({:delete_device, device}, _from, %{devices: existing_devices} = state) do
    new_devices = delete_device(device, existing_devices)

    {:reply, :ok, %{state | devices: new_devices}}
  end

  @impl GenServer
  def handle_call({:set_rules, settings}, _from, _settings) do
    cli().restore(settings)

    {:reply, :ok, settings}
  end

  @impl GenServer
  def handle_call({:add_user, user_id}, _from, %{users: existing_users} = state) do
    new_users = add_user(user_id, existing_users)

    {:reply, :ok, %{state | users: new_users}}
  end

  @impl GenServer
  def handle_call({:delete_user, user_id}, _from, %{users: existing_users} = state) do
    new_users = delete_user(user_id, existing_users)

    {:reply, :ok, %{state | users: new_users}}
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end

  defp add_rule(rule, existing_rules) do
    cli().add_rule(rule)

    MapSet.put(existing_rules, rule)
  end

  defp delete_rule(rule, existing_rules) do
    cli().delete_rule(rule)

    MapSet.delete(existing_rules, rule)
  end

  defp add_user(user_id, existing_users) do
    cli().add_user(user_id)

    MapSet.put(existing_users, user_id)
  end

  defp delete_user(user_id, existing_users) do
    cli().delete_user(user_id)

    MapSet.delete(existing_users, user_id)
  end

  defp add_device(device, existing_devices) do
    cli().add_device(device)

    MapSet.put(existing_devices, device)
  end

  defp delete_device(device, existing_devices) do
    cli().delete_device(device)

    MapSet.delete(existing_devices, device)
  end
end
