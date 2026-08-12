defmodule Portal.Workers.RevocationEndpointErrorNotification do
  @moduledoc """
  Oban worker telling admins that certificate revocation is no longer checked.

  A device whose certificate a CA has revoked keeps connecting while the
  endpoint publishing that fact cannot be reached, so this is the one failure in
  device trust that makes the portal quietly more permissive. Nothing in the
  product surfaces it on its own, which is why it is emailed.

  Runs once a day, on the same schedule a failing log sink uses:
  - error_email_count < 3: daily
  - error_email_count 3-6: every 3 days
  - error_email_count 7-9: weekly

  After 10 emails, stop.

  Due-ness comes from last_error_email_at rather than one cron per frequency:
  with separate crons, an endpoint crossing a bucket boundary on a day two
  schedules coincide would be emailed by both. Thresholds sit a few hours under
  the nominal interval so cron jitter cannot skip a day.
  """

  use Oban.Worker,
    queue: :sync_error_notifications,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Billing
  alias Portal.Crypto.X509
  alias Portal.Mailer
  alias Portal.Revocation.Failure
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Database.errored_disabled_endpoints()
    |> Enum.filter(&due_for_email?(&1, now))
    |> Enum.each(&send_notification/1)

    :ok
  end

  defp due_for_email?(%{last_error_email_at: nil}, _now), do: true

  defp due_for_email?(endpoint, now) do
    threshold_hours =
      cond do
        endpoint.error_email_count < 3 -> 20
        endpoint.error_email_count <= 6 -> 70
        true -> 166
      end

    cutoff = DateTime.add(now, -threshold_hours, :hour)
    DateTime.before?(endpoint.last_error_email_at, cutoff)
  end

  defp send_notification(endpoint) do
    Logger.info("Sending certificate revocation error notification",
      account_id: endpoint.account_id,
      issuer: X509.describe_name(endpoint.issuer),
      distribution_point: endpoint.distribution_point,
      error_email_count: endpoint.error_email_count
    )

    admins = Database.get_account_admin_actors(endpoint.account_id)

    cond do
      admins == [] ->
        Logger.error("No admin actors found for account",
          account_id: endpoint.account_id,
          issuer: X509.describe_name(endpoint.issuer)
        )

      # Leave the count alone so a returning account still gets the full series.
      dormant?(endpoint.account) ->
        Logger.info("Skipping certificate revocation error notification for dormant account",
          account_id: endpoint.account_id,
          issuer: X509.describe_name(endpoint.issuer)
        )

      true ->
        record_error_email(endpoint)
        send_email_notification(admins, endpoint)
    end
  end

  defp dormant?(account) do
    not Billing.paid_plan?(account) and not Database.account_active?(account.id)
  end

  defp send_email_notification(admins, endpoint) do
    recipient_emails = Enum.map(admins, & &1.email)

    # The send is attempted after the count is recorded, and a failure is logged
    # rather than raised: raising would roll the count back and email the same
    # admins again on the next run.
    revocation_email_module().revocation_endpoint_error_email(endpoint, recipient_emails)
    |> mailer_module().enqueue()
    |> case do
      {:ok, _result} ->
        Logger.info("Certificate revocation error email enqueued successfully",
          recipient_count: length(recipient_emails),
          account_id: endpoint.account_id
        )

      {:error, reason} ->
        Logger.error("Failed to enqueue certificate revocation error email",
          recipient_count: length(recipient_emails),
          reason: inspect(reason),
          account_id: endpoint.account_id
        )
    end
  end

  defp mailer_module do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:mailer_module, Mailer)
  end

  defp revocation_email_module do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:revocation_email_module, Mailer.RevocationEmail)
  end

  defp record_error_email(endpoint) do
    Database.record_error_email(endpoint, DateTime.utc_now())
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Revocation.Failure
    alias Portal.Safe

    def errored_disabled_endpoints do
      from(e in Portal.RevocationEndpoint,
        where: not is_nil(e.errored_at),
        where: e.is_disabled == true,
        where: e.disabled_reason == ^Failure.disabled_reason(),
        where: e.error_email_count < 10,
        preload: [:account]
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def record_error_email(endpoint, now) do
      from(e in Portal.RevocationEndpoint,
        where: e.account_id == ^endpoint.account_id,
        where: e.issuer == ^endpoint.issuer,
        where: e.distribution_point == ^endpoint.distribution_point
      )
      |> update(
        set: [
          error_email_count: ^(endpoint.error_email_count + 1),
          last_error_email_at: ^now,
          updated_at: ^now
        ]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
    end

    def get_account_admin_actors(account_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def account_active?(account_id) do
      from(sl in Portal.SessionLog, where: sl.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
