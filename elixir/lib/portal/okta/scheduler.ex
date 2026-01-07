defmodule Portal.Okta.Scheduler do
  @moduledoc """
  Worker to schedule Okta directory syncs.
  """
  use Oban.Worker, queue: :okta_scheduler, max_attempts: 1
  alias __MODULE__.DB
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling Okta directory sync jobs")

    DB.queue_sync_jobs()
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe

    def queue_sync_jobs do
      Safe.transact(fn ->
        from(d in Portal.Okta.Directory,
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
          {:ok, _job} = Portal.Okta.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
