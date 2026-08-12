defmodule Portal.Ocsp.Scheduler do
  @moduledoc """
  Worker to schedule OCSP status refreshes.

  Only issuers that publish no CRL are scheduled. Where a CA offers both, the
  list is one fetch covering every device while OCSP is one request per
  certificate, and responders are commonly billed per query, so the list wins.
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
    alias Portal.Safe

    def queue_sync_jobs do
      Safe.transact(fn ->
        from(e in Portal.RevocationEndpoint,
          join: a in Portal.Account,
          on: a.id == e.account_id,
          # The features table is global per-deployment state with no account_id.
          # credo:disable-for-next-line Credo.Check.Warning.MissingAccountIdInJoin
          join: f in Portal.Features,
          on: f.feature == :device_trust and f.enabled == true,
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM unnest(?) AS u WHERE u LIKE 'http://%' OR u LIKE 'https://%')",
              e.crl_urls
            ),
          where: e.ocsp_urls != [],
          where: a.is_disabled == false,
          where: e.is_disabled == false
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
