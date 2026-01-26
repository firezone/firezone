defmodule Portal.Entra.Scheduler do
  @moduledoc """
  Oban worker for scheduling the sync job.
  """

  use Oban.Worker, queue: :entra_scheduler, max_attempts: 1
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Entra directory sync jobs")

    Database.queue_sync_jobs()
  end

  defmodule Database do
    alias Portal.Repo
    import Ecto.Query

    def queue_sync_jobs do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.transaction(fn ->
        from(d in Portal.Entra.Directory,
          join: a in Portal.Account,
          on: a.id == d.account_id,
          where: d.is_disabled == false,
          where: is_nil(a.disabled_at),
          where: fragment("(?)->>'idp_sync' = 'true'", a.features)
        )

        # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
        |> Repo.stream()
        |> Stream.each(fn directory ->
          args = %{directory_id: directory.id}
          {:ok, _job} = Portal.Entra.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
