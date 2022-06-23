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
    cli().setup_rules()
    {:ok, settings} = GenServer.call(http_pid(), :load_settings, @init_timeout)
    cli().restore(settings)
    {:ok, settings}
  end

  @impl GenServer
  def handle_call({:add_rule, rule}, _from, {existing_users, existing_devices, existing_rules}) do
    new_rules = add_rule(rule, existing_rules)

    {:reply, :ok, {existing_users, existing_devices, new_rules}}
  end

  @impl GenServer
  def handle_call({:delete_rule, rule}, _from, {existing_users, existing_devices, existing_rules}) do
    new_rules = delete_rule(rule, existing_rules)

    {:reply, :ok, {existing_users, existing_devices, new_rules}}
  end

  @impl GenServer
  def handle_call(
        {:add_device, device},
        _from,
        {existing_users, existing_devices, existing_rules}
      ) do
    new_devices = add_device(device, existing_devices)

    {:reply, :ok, {existing_users, new_devices, existing_rules}}
  end

  @impl GenServer
  def handle_call(
        {:delete_device, device},
        _from,
        {existing_users, existing_devices, existing_rules}
      ) do
    new_devices = delete_device(device, existing_devices)

    {:reply, :ok, {existing_users, new_devices, existing_rules}}
  end

  @impl GenServer
  def handle_call({:set_rules, settings}, _from, _settings) do
    cli().restore(settings)

    {:reply, :ok, settings}
  end

  @impl GenServer
  def handle_call({:add_user, user_id}, _from, {existing_users, existing_devices, existing_rules}) do
    new_users = add_user(user_id, existing_users)

    {:reply, :ok, {new_users, existing_devices, existing_rules}}
  end

  @impl GenServer
  def handle_call(
        {:delete_user, user_id},
        _from,
        {existing_users, existing_devices, existing_rules}
      ) do
    new_users = delete_user(user_id, existing_users)

    {:reply, :ok, {new_users, existing_devices, existing_rules}}
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end

  defp add_rule(rule, existing_rules) do
    cli().add_rule(rule)

    existing_rules
    |> MapSet.put(rule)
  end

  defp delete_rule(rule, existing_rules) do
    cli().delete_rule(rule)

    existing_rules
    |> MapSet.delete(rule)
  end

  defp add_user(user_id, existing_users) do
    cli().add_user(user_id)

    existing_users
    |> MapSet.put(user_id)
  end

  defp delete_user(user_id, existing_users) do
    cli().delete_user(user_id)

    existing_users
    |> MapSet.delete(user_id)
  end

  defp add_device(device, existing_devices) do
    cli().add_device(device)

    existing_devices
    |> MapSet.put(device)
  end

  defp delete_device(device, existing_devices) do
    cli().delete_device(device)

    existing_devices
    |> MapSet.delete(device)
  end
end
