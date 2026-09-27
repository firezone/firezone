defmodule Portal.Workers.BackfillLogTables do
  @moduledoc """
  Explicitly enqueued by an operator after manual setup. Copies/verifies at
  most one bounded batch per stream per run, then snoozes to limit database
  load. Checkpoints commit with each batch. This worker never runs cutover.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    size = Map.get(args, "batch_size", 500)

    results =
      for source <- ~w[session_logs api_request_logs change_logs] do
        Portal.LogTableMigration.step(source, size)
      end

    if Enum.all?(results, &(&1 in [:ready, :cutover])), do: :ok, else: {:snooze, 1}
  end
end
