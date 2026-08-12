defmodule Portal.Intune.Scheduler do
  use Oban.Worker, queue: :intune_scheduler, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    __MODULE__.Database.queue_sync_jobs()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def queue_sync_jobs do
      Safe.transact(fn ->
        from(i in Portal.Intune.Integration,
          join: a in Portal.Account,
          on: a.id == i.account_id,
          where: i.is_disabled == false,
          where: i.is_verified == true,
          where: a.is_disabled == false
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn integration ->
          {:ok, _job} =
            %{account_id: integration.account_id, device_integration_id: integration.id}
            |> Portal.Intune.Sync.new()
            |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
