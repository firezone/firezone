defmodule Domain.Entra.Jobs.Scheduler do
  use Oban.Worker, queue: :entra_scheduler, max_attempts: 1
  alias Domain.{Entra, Repo}
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Entra directory sync jobs")

    result =
      Repo.transact(fn ->
        directories = Entra.stream_directories_for_sync() |> Enum.to_list()
        Logger.debug("Found #{length(directories)} Entra directories to sync")

        results =
          Enum.map(directories, fn directory ->
            job =
              Entra.Jobs.Sync.new(%{id: directory.id},
                unique: [
                  # Give currently "executing" Entra sync jobs 10 minutes to complete before allowing a retry
                  period: 600,
                  states: [:executing],
                  keys: [:id]
                ]
              )

            # We insert one at a time to ensure uniqueness validations are respected
            case Oban.insert(job) do
              {:ok, _job} ->
                Logger.debug("Scheduled sync job for directory #{directory.id}")
                1

              {:error, reason} ->
                Logger.debug("Skipped sync job for directory #{directory.id}: #{inspect(reason)}")
                0
            end
          end)

        total_scheduled = Enum.sum(results)
        {:ok, total_scheduled}
      end)

    case result do
      {:ok, count} ->
        Logger.debug("Scheduled #{count} Entra directory sync jobs")
        {:ok, %{scheduled: count}}

      {:error, reason} ->
        Logger.error("Failed to schedule Entra directory sync jobs",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
