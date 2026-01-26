defmodule Portal.Google.Scheduler do
  @moduledoc """
  Oban worker for scheduling the sync job.
  """

  use Oban.Worker, queue: :google_scheduler, max_attempts: 1
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Google directory sync jobs")

    Database.queue_sync_jobs()
  end

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def queue_sync_jobs do
      Safe.transact(fn ->
        from(d in Portal.Google.Directory,
          join: a in Portal.Account,
          on: a.id == d.account_id,
          where: d.is_disabled == false,
          where: is_nil(a.disabled_at),
          where: fragment("(?)->>'idp_sync' = 'true'", a.features)
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn directory ->
          args = %{directory_id: directory.id}
          {:ok, _job} = Portal.Google.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
