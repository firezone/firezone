defmodule Portal.Ocsp.Scheduler do
  @moduledoc """
  Worker to schedule OCSP status refreshes.

  Only issuers whose CRLs do not cover them are scheduled: a CA that publishes
  no list, or one whose list is off or expired. Where a list is current, it is
  one fetch covering every device while OCSP is one request per certificate,
  and responders are commonly billed per query, so the list wins.
  """
  use Oban.Worker, queue: :ocsp_scheduler, max_attempts: 1
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling OCSP refresh jobs")

    Database.queue_sync_jobs()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.RevocationEndpoint
    alias Portal.Safe
    require RevocationEndpoint

    def queue_sync_jobs do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Safe.transact(fn ->
        from(e in RevocationEndpoint,
          join: a in Portal.Account,
          on: a.id == e.account_id,
          where: not RevocationEndpoint.crl_covered?(e.account_id, e.issuer, ^now),
          where: e.ocsp_urls != [],
          where: a.is_disabled == false,
          where: e.ocsp_is_disabled == false
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn endpoint ->
          args = %{
            account_id: endpoint.account_id,
            issuer: Base.encode64(endpoint.issuer),
            distribution_point: endpoint.distribution_point
          }

          {:ok, _job} = Portal.Ocsp.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
