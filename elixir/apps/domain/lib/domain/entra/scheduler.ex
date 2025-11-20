defmodule Domain.Entra.Scheduler do
  @moduledoc """
  Oban worker for scheduling the sync job.
  """

  use Oban.Worker, queue: :entra_scheduler, max_attempts: 1
  alias Domain.Safe
  alias __MODULE__.Query
  require Logger

  @sync_job_opts [
    unique: [
      # Allow 10 minutes for jobs to complete before allowing another to be scheduled
      period: 60 * 10,
      states: [:available, :scheduled, :executing],
      keys: [:directory_id]
    ]
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Entra directory sync jobs")

    Safe.transact(fn ->
      Query.directories_to_sync()
      |> Safe.unscoped()
      |> Safe.stream()
      |> Stream.each(&queue_sync_job/1)
      |> Stream.run()
    end)

    :ok
  end

  defp queue_sync_job(directory) do
    args = %{directory_id: directory.id}
    {:ok, job} = Domain.Entra.Sync.new(args, @sync_job_opts) |> Oban.insert()

    {:ok, _directory} =
      Ecto.Changeset.cast(directory, %{current_job_id: job.id}, [:current_job_id])
      |> Safe.unscoped()
      |> Safe.update()
  end

  defmodule Query do
    import Ecto.Query

    def directories_to_sync do
      from(d in Domain.Entra.Directory,
        as: :directories,
        where: d.is_disabled == false
      )
    end
  end
end
