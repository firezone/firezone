defmodule Portal.Crl.Scheduler do
  @moduledoc """
  Worker to schedule certificate revocation list refreshes.

  One job per partition rather than per issuer, since a CA may split its list
  across several distribution points and each carries its own schedule. Only
  partitions with an address are queued, and only once the cached list is due: a
  CRL carries its own `nextUpdate`, so refreshing before then would fetch the
  same bytes.

  A partition is due once either its complete list or the delta published on top
  of it is, because a CA commonly leaves the complete list valid for a week while
  replacing the delta daily.
  """
  use Oban.Worker, queue: :crl_scheduler, max_attempts: 1
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling certificate revocation list refresh jobs")

    if Portal.Features.enabled?(:trust_anchors) do
      Database.queue_sync_jobs()
    else
      {:ok, :skipped}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    # Refreshed early rather than exactly at nextUpdate, so a list is never
    # served past its own expiry just because the scheduler ticked late.
    @refresh_margin_seconds 3600

    def queue_sync_jobs do
      due_at = DateTime.add(DateTime.utc_now(), @refresh_margin_seconds, :second)

      Safe.transact(fn ->
        from(e in Portal.RevocationEndpoint,
          join: a in Portal.Account,
          on: a.id == e.account_id,
          where: e.crl_urls != [],
          where: a.is_disabled == false,
          where: e.is_disabled == false,
          # A failed delta leaves the partition due, so a delta that is broken
          # rather than absent is retried instead of waiting out the complete
          # list's own validity.
          where:
            is_nil(e.crl_next_update) or e.crl_next_update <= ^due_at or
              e.delta_next_update <= ^due_at or not is_nil(e.delta_error)
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn endpoint ->
          args = %{
            account_id: endpoint.account_id,
            issuer: Base.encode64(endpoint.issuer),
            distribution_point: endpoint.distribution_point
          }

          {:ok, _job} = Portal.Crl.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
