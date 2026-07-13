defmodule Portal.Workers.LogSinkErrorNotification do
  @moduledoc """
  Oban worker for sending log sink delivery error notifications.

  Three notification frequencies based on error_email_count:
  - Daily: error_email_count < 3 (0, 1, 2)
  - Every 3 days: error_email_count 3-6
  - Weekly: error_email_count 7-10

  After 10 failed notifications, stop sending emails.
  """

  use Oban.Worker,
    queue: :sync_error_notifications,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Mailer
  alias Portal.Splunk
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"frequency" => frequency}}) do
    Splunk.LogSink
    |> Database.errored_disabled_sinks(frequency)
    |> Enum.each(&send_notification(&1, frequency))

    :ok
  end

  defp send_notification(sink, frequency) do
    Logger.info("Sending log sink error notification",
      log_sink_id: sink.id,
      account_id: sink.account_id,
      frequency: frequency,
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
        increment_error_email_count(sink)
        send_email_notification(admins, sink, frequency)
    end
  end

  defp send_email_notification(admins, sink, frequency) do
    recipient_emails = Enum.map(admins, & &1.email)
    stats = Database.delivery_stats(sink)

    Logger.info("Sending log sink error email",
      recipient_count: length(recipient_emails),
      log_sink_id: sink.id,
      log_sink_name: sink.name,
      frequency: frequency
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

  defp increment_error_email_count(sink) do
    new_count = sink.error_email_count + 1

    {:ok, _sink} =
      sink
      |> Ecto.Changeset.cast(%{"error_email_count" => new_count}, [:error_email_count])
      |> Database.update_sink()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    # Sinks that are currently disabled due to delivery errors. Client errors
    # disable a sink immediately; transient errors disable it after 24 hours
    # of continuous failure. Admins are only notified once a sink is disabled.
    def errored_disabled_sinks(schema, frequency) do
      schema
      |> errored_disabled_sinks_query(frequency)
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    defp errored_disabled_sinks_query(schema, "daily") do
      from(s in schema,
        where: not is_nil(s.errored_at),
        where: s.is_disabled == true,
        where: s.disabled_reason == "Sync error",
        where: s.error_email_count < 3,
        preload: [:account]
      )
    end

    defp errored_disabled_sinks_query(schema, "three_days") do
      from(s in schema,
        where: not is_nil(s.errored_at),
        where: s.is_disabled == true,
        where: s.disabled_reason == "Sync error",
        where: s.error_email_count >= 3,
        where: s.error_email_count <= 6,
        preload: [:account]
      )
    end

    defp errored_disabled_sinks_query(schema, "weekly") do
      from(s in schema,
        where: not is_nil(s.errored_at),
        where: s.is_disabled == true,
        where: s.disabled_reason == "Sync error",
        where: s.error_email_count >= 7,
        where: s.error_email_count < 10,
        preload: [:account]
      )
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
