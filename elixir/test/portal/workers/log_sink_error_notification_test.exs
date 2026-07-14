defmodule Portal.Workers.LogSinkErrorNotificationTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.LogSinkFixtures
  import Portal.OutboundEmailTestHelpers

  alias Portal.LogSinkCursor
  alias Portal.Workers.LogSinkErrorNotification

  defmodule FailingLogSinkEmail do
    def log_sink_error_email(_sink, _stats, _recipients), do: :failing_email
  end

  defmodule FailingMailer do
    def enqueue(:failing_email), do: {:error, :injected_failure}
  end

  defp errored_sink_fixture(account, attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      account: account,
      is_disabled: true,
      disabled_reason: "Sync error",
      error_message: "Splunk HEC returned HTTP 403: Invalid token (code 4)",
      errored_at: DateTime.utc_now()
    })
    |> splunk_log_sink_fixture()
  end

  describe "perform/1" do
    test "sends a detailed email to admins and increments error_email_count" do
      account = account_fixture(features: %{log_sinks: true})
      admin = admin_actor_fixture(account: account)
      sink = errored_sink_fixture(account, name: "SOC Splunk")

      now = DateTime.utc_now()

      Repo.insert_all(LogSinkCursor, [
        %{
          account_id: account.id,
          log_sink_id: sink.id,
          stream: :session,
          phase: :live,
          cursor: 100,
          synced_count: 42,
          last_synced_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      assert :ok = perform_job(LogSinkErrorNotification, %{})

      updated_sink = reload_sink(sink)
      assert updated_sink.error_email_count == 1
      assert updated_sink.last_error_email_at

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Log Sink Delivery Error - SOC Splunk"
      assert {"", admin.email} in email.bcc
      assert email.text_body =~ "Invalid token"
      assert email.text_body =~ "Events Delivered: 42"
      assert email.text_body =~ "Log Streams: Change, Session, API request, Flow"
      assert email.text_body =~ "Edit and Save"
      assert email.text_body =~ "settings/log_sinks"
      assert email.html_body =~ "Invalid token"
      assert email.html_body =~ "Edit and Save"
    end

    test "notifies for Datadog sinks with the provider's own details" do
      account = account_fixture(features: %{log_sinks: true})
      admin_actor_fixture(account: account)

      datadog_log_sink_fixture(
        account: account,
        name: "SOC Datadog",
        site: "datadoghq.eu",
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message: "Datadog returned HTTP 403: Invalid API key",
        errored_at: DateTime.utc_now()
      )

      assert :ok = perform_job(LogSinkErrorNotification, %{})

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Log Sink Delivery Error - SOC Datadog"
      assert email.text_body =~ "Type: Datadog"
      assert email.text_body =~ "Destination: datadoghq.eu"
      assert email.text_body =~ "API key is valid and unrevoked"
    end

    test "a sink crossing a frequency bucket is not emailed twice in one day" do
      account = account_fixture(features: %{log_sinks: true})
      admin_actor_fixture(account: account)

      sink =
        errored_sink_fixture(account,
          error_email_count: 2,
          last_error_email_at: hours_ago(21)
        )

      assert :ok = perform_job(LogSinkErrorNotification, %{})
      assert [_email] = collect_queued_emails(account.id)
      assert reload_sink(sink).error_email_count == 3

      # The increment moved it into the every-3-days bucket; a second run the
      # same day (or the next) must not pick it up again.
      assert :ok = perform_job(LogSinkErrorNotification, %{})
      assert [_email] = collect_queued_emails(account.id)
      assert reload_sink(sink).error_email_count == 3
    end

    test "email frequency follows the error_email_count bucket" do
      account = account_fixture(features: %{log_sinks: true})
      admin_actor_fixture(account: account)

      three_days_fresh = errored_sink_fixture(account, error_email_count: 3, last_error_email_at: hours_ago(24))
      three_days_due = errored_sink_fixture(account, error_email_count: 3, last_error_email_at: hours_ago(71))
      weekly_fresh = errored_sink_fixture(account, error_email_count: 7, last_error_email_at: hours_ago(120))
      weekly_due = errored_sink_fixture(account, error_email_count: 7, last_error_email_at: hours_ago(167))

      assert :ok = perform_job(LogSinkErrorNotification, %{})

      assert length(collect_queued_emails(account.id)) == 2
      assert reload_sink(three_days_fresh).error_email_count == 3
      assert reload_sink(three_days_due).error_email_count == 4
      assert reload_sink(weekly_fresh).error_email_count == 7
      assert reload_sink(weekly_due).error_email_count == 8
    end

    test "stops notifying after 10 emails" do
      account = account_fixture(features: %{log_sinks: true})
      admin_actor_fixture(account: account)

      sink =
        errored_sink_fixture(account,
          error_email_count: 10,
          last_error_email_at: hours_ago(24 * 30)
        )

      assert :ok = perform_job(LogSinkErrorNotification, %{})

      assert collect_queued_emails(account.id) == []
      assert reload_sink(sink).error_email_count == 10
    end

    test "ignores healthy and admin-disabled sinks" do
      account = account_fixture(features: %{log_sinks: true})
      admin_actor_fixture(account: account)

      splunk_log_sink_fixture(account: account)

      splunk_log_sink_fixture(
        account: account,
        is_disabled: true,
        disabled_reason: "Disabled by admin"
      )

      assert :ok = perform_job(LogSinkErrorNotification, %{})

      assert collect_queued_emails(account.id) == []
    end

    test "logs enqueue failures and still increments error_email_count" do
      Portal.Config.put_env_override(:portal, LogSinkErrorNotification,
        mailer_module: FailingMailer,
        log_sink_email_module: FailingLogSinkEmail
      )

      account = account_fixture(features: %{log_sinks: true})
      admin_actor_fixture(account: account)
      sink = errored_sink_fixture(account)

      assert :ok = perform_job(LogSinkErrorNotification, %{})

      assert reload_sink(sink).error_email_count == 1
      assert collect_queued_emails(account.id) == []
    end
  end

  defp reload_sink(sink) do
    Repo.get_by!(Portal.Splunk.LogSink, account_id: sink.account_id, id: sink.id)
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours, :hour)
  end
end
