defmodule Domain.Jobs.Executors.Concurrent do
  @moduledoc """
  This module starts a GenServer that executes a callback function
  on a given interval on each node that runs the jobs. This means
  concurrency control should be implemented in the callback function
  itself (eg. by using `SELECT ... FOR UPDATE SKIP LOCKED`) or
  by using advisory locks (see `reject_locked/2`).

  If you need globally unique jobs see `Domain.Jobs.Executors.GloballyUnique`.
  """
  use GenServer
  require Logger
  require OpenTelemetry.Tracer

  @doc """
  Initializes the worker state.
  """
  @callback state(config :: term()) :: {:ok, state :: term()}

  @doc """
  Executes the callback function with the state created in `c:state/1`.
  """
  @callback execute(state :: term()) :: :ok

  def start_link({module, interval, config}) do
    GenServer.start_link(__MODULE__, {module, interval, config})
  end

  @impl true
  def init({module, interval, config}) do
    initial_delay = Keyword.get(config, :initial_delay, 0)

    with {:ok, worker_state} <- module.state(config) do
      {:ok, {module, worker_state, interval}, initial_delay}
    end
  end

  @impl true
  def handle_info(:timeout, {_module, _worker_state_, interval} = state) do
    :ok = schedule_tick(interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, {module, worker_state, interval} = state) do
    :ok = execute_handler(module, worker_state)
    :ok = schedule_tick(interval)
    {:noreply, state}
  end

  # tick is scheduled by using a timeout message instead of `:timer.send_interval/2`,
  # because we don't want jobs to overlap if they take too long to execute
  defp schedule_tick(interval) do
    _ = Process.send_after(self(), :tick, interval)
    :ok
  end

  defp execute_handler(module, worker_state) do
    job_callback = "#{module}.execute/2"

    attributes = [
      job_runner: __MODULE__,
      job_execution_id: Ecto.UUID.generate(),
      job_callback: job_callback
    ]

    Logger.metadata(attributes)

    OpenTelemetry.Tracer.with_span job_callback, attributes: attributes do
      _ = module.execute(worker_state)
    end

    :ok
  end

  @doc """
  A helper function that acquires an exclusive transaction-level advisory lock for each given row in the given table
  and returns only the rows that were successfully locked.

  This function is useful when you want to ensure that only one process is working on a given
  row(s) at a time, without using actual row-level locks that can cause deadlocks and timeouts
  for long-running transactions (like IdP syncs).

  Execution of this function should be wrapped in a transaction block (eg. `Ecto.Repo.checkout/2`),
  the locks are released when the transaction is committed or rolled back.

  ## Implementation notes

  Postgres allows to either use one `bigint` or two-`int` for advisory locks,
  we use the latter to avoid contention on a single value between processed tables
  by using the oid of the table as as first of the lock arguments.

  The lock is acquired by the `id` (second `int`) of the row but since our ids are UUIDs we also
  hash them to fit into `int` range, this opens a possibility of hash collisions but a negligible
  trade-off since the chances of a collision is very low and jobs will be restarted anyways only
  delaying their execution.

  `mod/2` is used to roll over the hash value to fit into the `int` range since `hashtext/1` return
  can change between Postgres versions.
  """
  def reject_locked(table, rows) do
    ids = Enum.map(rows, & &1.id)

    %Postgrex.Result{rows: not_locked_ids} =
      Ecto.Adapters.SQL.query!(
        Domain.Repo,
        """
        SELECT id
        FROM unnest($1::text[]) AS t(id)
        WHERE pg_try_advisory_xact_lock(($2::text)::regclass::oid::int, mod(hashtext(t.id), 2147483647)::int)
        """,
        [ids, table]
      )

    not_locked_ids = Enum.map(not_locked_ids, fn [id] -> id end)

    Enum.filter(rows, fn row -> row.id in not_locked_ids end)
  end
end
