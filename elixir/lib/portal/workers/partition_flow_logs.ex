defmodule Portal.Workers.PartitionFlowLogs do
  @moduledoc false

  # Compatibility for jobs already queued with the old worker name during a
  # rolling deploy. Only PartitionLogTables is scheduled; all DDL lives there.
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(job), do: Portal.Workers.PartitionLogTables.perform(job)
end
