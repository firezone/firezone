defmodule Portal.Intune.Scheduler do
  use Oban.Worker, queue: :intune_scheduler, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Portal.Features.enabled?(:device_posture) do
      __MODULE__.Database.queue_sync_jobs()
    else
      {:ok, :skipped}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def queue_sync_jobs do
      Safe.transact(fn ->
        from(i in Portal.Intune.PostureProvider,
          join: a in Portal.Account,
          on: a.id == i.account_id,
          where: i.is_disabled == false,
          where: i.is_verified == true,
          where: a.is_disabled == false,
          where: fragment("(?)->>'device_posture' = 'true'", a.features)
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn provider ->
          {:ok, _job} =
            %{account_id: provider.account_id, posture_provider_id: provider.id}
            |> Portal.Intune.Sync.new()
            |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
