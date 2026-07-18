defmodule Portal.Workers.LogSinkErrorNotification do
  @moduledoc """
  Oban worker for sending log sink delivery error notifications.

  Runs once a day; how often a sink is emailed depends on how many error
  emails it has already received:
  - error_email_count < 3: daily
  - error_email_count 3-6: every 3 days
  - error_email_count 7-9: weekly

  After 10 emails, stop.

  Due-ness comes from last_error_email_at rather than one cron per
  frequency: with separate crons, a sink crossing a bucket boundary on a day
  two schedules coincide would be emailed by both. Thresholds sit a few
  hours under the nominal interval so cron jitter cannot skip a day.
  """

  use Oban.Worker,
    queue: :sync_error_notifications,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Mailer
  alias __MODULE__.Database
  require Logger

  @sink_schemas [
    Portal.Splunk.LogSink,
    Portal.Datadog.LogSink,
    Portal.NewRelic.LogSink,
    Portal.Elastic.LogSink,
    Portal.Sentinel.LogSink,
    Portal.S3.LogSink,
    Portal.QRadar.LogSink
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Enum.each(@sink_schemas, fn schema ->
      schema
      |> Database.errored_disabled_sinks()
      |> Enum.filter(&due_for_email?(&1, now))
      |> Enum.each(&send_notification/1)
    end)

    :ok
  end

  defp due_for_email?(%{last_error_email_at: nil}, _now), do: true

  defp due_for_email?(sink, now) do
    threshold_hours =
      cond do
        sink.error_email_count < 3 -> 20
        sink.error_email_count <= 6 -> 70
        true -> 166
      end

    cutoff = DateTime.add(now, -threshold_hours, :hour)
    DateTime.before?(sink.last_error_email_at, cutoff)
  end

  defp send_notification(sink) do
    Logger.info("Sending log sink error notification",
      log_sink_id: sink.id,
      account_id: sink.account_id,
      error_email_count: sink.error_email_count
    )

    admins = Database.get_account_admin_actors(sink.account_id)

    case admins do
      [] ->
        Logger.error("No admin actors found for account",
          account_id: sink.account_id,
          log_sink_id: sink.id
        )

      admins ->
        record_error_email(sink)
        send_email_notification(admins, sink)
    end
  end

  defp send_email_notification(admins, sink) do
    recipient_emails = Enum.map(admins, & &1.email)
    stats = Database.delivery_stats(sink)

    Logger.info("Sending log sink error email",
      recipient_count: length(recipient_emails),
      log_sink_id: sink.id,
      log_sink_name: sink.name
    )

    # Attempt to send the email but log errors if it fails. Important not to
    # raise here otherwise we won't increment the error email count and
    # potentially spam admins with emails.
    log_sink_email_module().log_sink_error_email(sink, stats, recipient_emails)
    |> mailer_module().enqueue()
    |> case do
      {:ok, _result} ->
        Logger.info("Log sink error email enqueued successfully",
          recipient_count: length(recipient_emails),
          log_sink_id: sink.id
        )

      {:error, reason} ->
        Logger.error("Failed to enqueue log sink error email",
          recipient_count: length(recipient_emails),
          reason: inspect(reason),
          log_sink_id: sink.id
        )
    end
  end

  defp mailer_module do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:mailer_module, Mailer)
  end

  defp log_sink_email_module do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:log_sink_email_module, Mailer.LogSinkEmail)
  end

  defp record_error_email(sink) do
    attrs = %{
      error_email_count: sink.error_email_count + 1,
      last_error_email_at: DateTime.utc_now()
    }

    {:ok, _sink} =
      sink
      |> Ecto.Changeset.cast(attrs, [:error_email_count, :last_error_email_at])
      |> Database.update_sink()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    # Sinks that are currently disabled due to delivery errors. Client errors
    # disable a sink immediately; transient errors disable it after 24 hours
    # of continuous failure. Admins are only notified once a sink is disabled.
    def errored_disabled_sinks(schema) do
      from(s in schema,
        where: not is_nil(s.errored_at),
        where: s.is_disabled == true,
        where: s.disabled_reason == "Sync error",
        where: s.error_email_count < 10,
        preload: [:account]
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    def update_sink(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    def get_account_admin_actors(account_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    def delivery_stats(sink) do
      from(c in Portal.LogSinkCursor,
        where: c.account_id == ^sink.account_id,
        where: c.log_sink_id == ^sink.id,
        select: %{
          delivered: coalesce(type(sum(c.synced_count), :integer), 0),
          last_delivered_at: max(c.last_synced_at)
        }
      )
      |> Safe.unscoped(:replica)
      |> Safe.one()
    end
  end
end
