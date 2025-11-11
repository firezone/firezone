defmodule Domain.Okta.Scheduler do
  @moduledoc """
  Worker to schedule Okta directory syncs.
  """
  use Oban.Worker, queue: :okta_scheduler, max_attempts: 1
  alias Domain.Safe
  alias __MODULE__.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Okta directory sync jobs")

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
    {:ok, _job} = Domain.Okta.Sync.new(args) |> Oban.insert()
  end

  defmodule Query do
    import Ecto.Query

    def directories_to_sync do
      from(d in Domain.Okta.Directory,
        as: :directories,
        where: d.is_disabled == false
      )
    end
  end
end
