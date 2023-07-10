defmodule Domain.Jobs.Executors.Global do
  @moduledoc """
  This module is an abstraction on top of a GenServer that executes a callback function
  on a given interval on a globally unique process in an Erlang cluster.

  It is mainly designed to run recurrent jobs that poll the database using a filter which
  prevents duplicate execution, eg:

      SELECT *
      FROM my_table
      WHERE processed_at IS NULL
        AND processing_cancelled_at IS NULL
      LIMIT 100;

  you can also keep manual track of retry attempts like so:

      UPDATE my_table
      SET processing_attempts_count = processing_attempts_count + 1
      WHERE processed_at IS NULL
        AND processing_cancelled_at IS NULL
        AND processing_attempts_count < 3
      LIMIT 100
      RETURNING *;

  and then updates the processing flag on job is completed:

      UPDATE my_table SET processed_at = NOW() WHERE id = ?;

  it is also recommended to cancel jobs to prevent them from being executed indefinitely:

      UPDATE my_table SET processing_cancelled_at = NOW() WHERE id = ?;

  Even though this does not prove fully fledged job queue, it is a good enough solution
  for many use cases like refreshing tokens, deactivating users and even dispatching
  emails, while keeping the code simple, company-owned, maintainable and easy to reason about.

  ## Design Limitations

  1. The interval is not guaranteed to be precise. The timer starts after the execution is
  finished, so next tick is always delayed by the execution time.

  2. Because we don't persist the state the interval will be reset on every restart (eg. during deployment, or
  crash loops in your supervision tree), so the interval should not be too big.

  3. The jobs must be idempotent. Callback is executed at least once in an erlang cluster and in the given interval,
  for example if you restart the cluster - the job execution can be repeated. That's why we don't have helpers
  that set interval in hours or more.
  """
  use GenServer
  require Logger

  def start_link({{module, function}, interval, config}) do
    GenServer.start_link(__MODULE__, {{module, function}, interval, config})
  end

  @impl true
  def init({{module, function}, interval, config}) do
    name = global_name(module, function)

    # `random_notify_name` is used to avoid name conflicts in a cluster during deployments and
    # network splits, it randomly selects one of the duplicate pids for registration,
    # and sends the message {global_name_conflict, Name} to the other pid so that they stop
    # tying to claim job queue leadership.
    with :no <- :global.register_name(name, self(), &:global.random_notify_name/3),
         pid when is_pid(pid) <- :global.whereis_name(name) do
      # we monitor the leader process so that we start a race to become a new leader with it's down
      monitor_ref = Process.monitor(pid)
      {:ok, {{{module, function}, interval, config}, {:fallback, pid, monitor_ref}}, :hibernate}
    else
      :yes ->
        Logger.debug("Recurrent job will be handled on this node",
          module: module,
          function: function
        )

        initial_delay = Keyword.get(config, :initial_delay, 0)
        {:ok, {{{module, function}, interval, config}, :leader}, initial_delay}

      :undefined ->
        Logger.warning("Recurrent job leader exists but is not yet available",
          module: module,
          function: function
        )

        _timer_ref = :timer.sleep(100)
        init(module)
    end
  end

  @impl true
  def handle_info(:timeout, {{{_module, _name}, interval, _config}, :leader} = state) do
    :ok = schedule_tick(interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:global_name_conflict, {__MODULE__, module, function}},
        {{{module, function}, interval, config}, _leader_or_fallback} = state
      ) do
    name = global_name(module, function)

    with pid when is_pid(pid) <- :global.whereis_name(name) do
      monitor_ref = Process.monitor(pid)
      state = {{{module, function}, interval, config}, {:fallback, pid, monitor_ref}}
      {:noreply, state, :hibernate}
    else
      :undefined ->
        Logger.warning("Recurrent job name conflict",
          module: module,
          function: function
        )

        _timer_ref = :timer.sleep(100)
        handle_info({:global_name_conflict, module}, state)
    end
  end

  def handle_info(
        {:DOWN, _ref, :process, _pid, reason},
        {{{module, function}, interval, config}, {:fallback, pid, _monitor_ref}}
      ) do
    # Solves the "Retry Storm" antipattern
    backoff_with_jitter = :rand.uniform(200) - 1
    _timer_ref = :timer.sleep(backoff_with_jitter)

    Logger.info("Recurrent job leader is down",
      module: module,
      function: function,
      leader_pid: inspect(pid),
      leader_exit_reason: inspect(reason, pretty: true)
    )

    case init({{module, function}, interval, config}) do
      {:ok, state, :hibernate} -> {:noreply, state, :hibernate}
      {:ok, state, _initial_delay} -> {:noreply, state, 0}
    end
  end

  @impl true
  def handle_info(:tick, {_definition, {:fallback, _pid, _monitor_ref}} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, {{{module, function}, interval, config}, :leader} = state) do
    :ok = execute_handler(module, function, config)
    :ok = schedule_tick(interval)
    {:noreply, state}
  end

  # tick is scheduled by using a timeout message instead of `:timer.send_interval/2`,
  # because we jobs to overlap if they take too long to execute
  defp schedule_tick(interval) do
    _ = Process.send_after(self(), :tick, interval)
    :ok
  end

  defp execute_handler(module, function, config) do
    _ = apply(module, :execute, [function, config])
    :ok
  end

  defp global_name(module, function), do: name(module, function)
  defp name(module, function), do: {__MODULE__, module, function}
end
