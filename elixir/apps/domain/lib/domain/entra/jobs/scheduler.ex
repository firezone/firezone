defmodule Domain.Entra.Jobs.Scheduler do
  use Oban.Worker, queue: :entra_scheduler, max_attempts: 1
  alias Domain.{Entra, Repo}
  require Logger

  @insert_batch_size 1000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Entra directory sync jobs")

    result =
      Repo.transact(fn ->
        total_scheduled =
          Entra.stream_directories_for_sync()
          |> Stream.map(&Entra.Jobs.Sync.new(%{id: &1.id}))
          |> Stream.chunk_every(@insert_batch_size)
          |> Stream.map(&batch_insert/1)
          |> Enum.sum()

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

  defp batch_insert(batch) do
    Oban.insert_all(batch)
    |> length()
  end
end
