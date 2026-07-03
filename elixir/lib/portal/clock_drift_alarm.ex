defmodule Portal.ClockDriftAlarm do
  @moduledoc """
  Periodically compares the system clock against the database clock and logs
  an error when they diverge by more than one second.

  session_logs and flow_logs are ordered by timestamps sourced from both
  clocks (WAL commit timestamps and database defaults on one side,
  DateTime.utc_now/0 on the other), so unnoticed drift would silently skew
  that ordering.
  """
  use GenServer

  require Logger

  alias __MODULE__.Database

  @check_interval :timer.minutes(1)
  @max_drift_ms :timer.seconds(1)

  def start_link(opts) do
    config = Application.fetch_env!(:portal, __MODULE__)

    if Keyword.fetch!(config, :enabled) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check()
    schedule_check()
    {:noreply, state}
  end

  @doc false
  def check do
    report(Database.fetch_db_now(), DateTime.utc_now())
  end

  @doc false
  def report(db_now, sys_now) do
    drift_ms = DateTime.diff(db_now, sys_now, :millisecond)

    if abs(drift_ms) > @max_drift_ms do
      Logger.error("System clock drifts from the database clock", drift_ms: drift_ms)
    end

    :ok
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end

  defmodule Database do
    alias Portal.Safe

    def fetch_db_now do
      {:ok, %{rows: [[db_now]]}} =
        Safe.unscoped()
        |> Safe.query("SELECT now()", [])

      db_now
    end
  end
end
