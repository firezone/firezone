defmodule Portal.NewRelic.Scheduler do
  @moduledoc """
  Worker to schedule New Relic log sink deliveries.
  """
  use Oban.Worker, queue: :newrelic_scheduler, max_attempts: 1
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling New Relic log sink sync jobs")

    Database.queue_sync_jobs()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def queue_sync_jobs do
      Safe.transact(fn ->
        from(s in Portal.NewRelic.LogSink,
          join: a in Portal.Account,
          on: a.id == s.account_id,
          where: s.is_disabled == false,
          where: is_nil(a.disabled_at),
          where: fragment("(?)->>'log_sinks' = 'true'", a.features)
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn sink ->
          args = %{log_sink_id: sink.id}
          {:ok, _job} = Portal.NewRelic.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
