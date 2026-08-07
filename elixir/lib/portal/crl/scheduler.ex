defmodule Portal.Crl.Scheduler do
  @moduledoc """
  Worker to schedule certificate revocation list refreshes.

  Only anchors that have learned a CRL URL are scheduled, and only once their
  cached list is due: a CRL carries its own `nextUpdate`, so refreshing before
  then would fetch the same bytes.
  """
  use Oban.Worker, queue: :crl_scheduler, max_attempts: 1
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Scheduling certificate revocation list refresh jobs")

    Database.queue_sync_jobs()
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
        from(c in Portal.TrustAnchorCertificate,
          join: a in Portal.Account,
          on: a.id == c.account_id,
          where: not is_nil(c.crl_url),
          where: a.is_disabled == false,
          where: is_nil(c.crl_next_update) or c.crl_next_update <= ^due_at
        )
        |> Safe.unscoped()
        |> Safe.stream()
        |> Stream.each(fn certificate ->
          args = %{account_id: certificate.account_id, certificate_id: certificate.id}
          {:ok, _job} = Portal.Crl.Sync.new(args) |> Oban.insert()
        end)
        |> Stream.run()

        {:ok, :scheduled}
      end)
    end
  end
end
