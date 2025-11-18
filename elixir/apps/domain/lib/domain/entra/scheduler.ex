defmodule Domain.Entra.Scheduler do
  @moduledoc """
  Oban worker for scheduling the sync job.
  """

  use Oban.Worker, queue: :entra_scheduler, max_attempts: 1
  alias Domain.Safe
  alias __MODULE__.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Entra directory sync jobs")

    Safe.transact(fn ->
      Safe.unscoped()
      |> Safe.stream(Query.directories_to_sync())
      |> Stream.each(&queue_sync_job/1)
      |> Stream.run()
    end)

    :ok
  end

  defp queue_sync_job(directory) do
    {:ok, job} = Domain.Entra.Sync.new(%{directory_id: directory.id}) |> Oban.insert()
    changeset = Ecto.Changeset.cast(directory, %{current_job_id: job.id}, [:current_job_id])
    {:ok, _directory} = Safe.update(Safe.unscoped(), changeset)
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
