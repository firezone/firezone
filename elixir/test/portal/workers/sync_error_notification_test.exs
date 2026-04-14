defmodule Portal.Workers.SyncErrorNotificationTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.OktaDirectoryFixtures
  import Portal.OutboundEmailTestHelpers

  alias Portal.DirectorySync.ErrorHandler
  alias Portal.Workers.SyncErrorNotification

  defmodule FailingSyncEmail do
    def sync_error_email(_directory, _recipients), do: :failing_email
  end

  defmodule FailingMailer do
    def enqueue(:failing_email), do: {:error, :injected_failure}
  end

  describe "perform/1" do
    test "increments error_email_count for an Entra mail field validation error" do
      account = account_fixture(features: %{idp_sync: true})
      admin = admin_actor_fixture(account: account)

      directory = entra_directory_fixture(account: account, email_field: "mail")

      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Entra.SyncError{
        error: {:validation, "user 'user_123' has no valid email in 'mail' field"},
        directory_id: directory.id,
        step: :process_user
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      errored_directory = Repo.get!(Portal.Entra.Directory, directory.id)
      assert errored_directory.is_disabled == true
      assert errored_directory.disabled_reason == "Sync error"
      assert errored_directory.is_verified == false
      assert errored_directory.error_message =~ "has no valid email in 'mail' field"
      assert errored_directory.error_email_count == 0

      assert :ok = perform_job(SyncErrorNotification, notification_args("entra", "daily"))

      updated_directory = Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.error_email_count == 1

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Directory Sync Error - #{directory.name}"
      assert {"", admin.email} in email.bcc
      assert email.text_body =~ "has no valid email"
    end

    test "routes google directories through the three day frequency window" do
      account = account_fixture(features: %{idp_sync: true})
      admin = admin_actor_fixture(account: account)

      too_low =
        google_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 2, error_message: "too low")
        )

      eligible =
        google_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 3, error_message: "eligible")
        )

      too_high =
        google_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 7, error_message: "too high")
        )

      assert :ok = perform_job(SyncErrorNotification, notification_args("google", "three_days"))

      assert Repo.get!(Portal.Google.Directory, too_low.id).error_email_count == 2
      assert Repo.get!(Portal.Google.Directory, eligible.id).error_email_count == 4
      assert Repo.get!(Portal.Google.Directory, too_high.id).error_email_count == 7

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Directory Sync Error - #{eligible.name}"
      assert {"", admin.email} in email.bcc
      assert email.text_body =~ "eligible"
    end

    test "routes okta directories through the weekly frequency window" do
      account = account_fixture(features: %{idp_sync: true})
      admin = admin_actor_fixture(account: account)

      too_low =
        okta_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 6, error_message: "too low")
        )

      eligible =
        okta_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 7, error_message: "eligible")
        )

      maxed_out =
        okta_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 10, error_message: "maxed out")
        )

      assert :ok = perform_job(SyncErrorNotification, notification_args("okta", "weekly"))

      assert Repo.get!(Portal.Okta.Directory, too_low.id).error_email_count == 6
      assert Repo.get!(Portal.Okta.Directory, eligible.id).error_email_count == 8
      assert Repo.get!(Portal.Okta.Directory, maxed_out.id).error_email_count == 10

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Directory Sync Error - #{eligible.name}"
      assert {"", admin.email} in email.bcc
      assert email.text_body =~ "eligible"
    end

    test "logs and skips notification when the account has no active admins" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        entra_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 0, error_message: "no admins")
        )

      log =
        capture_log(fn ->
          assert :ok = perform_job(SyncErrorNotification, notification_args("entra", "daily"))
        end)

      assert log =~ "No admin actors found for account"
      assert log =~ directory.id
      assert Repo.get!(Portal.Entra.Directory, directory.id).error_email_count == 0
      refute_email_queued(account.id)
    end

    test "logs enqueue failures and still increments error_email_count" do
      Portal.Config.put_env_override(:portal, SyncErrorNotification,
        mailer_module: FailingMailer,
        sync_email_module: FailingSyncEmail
      )

      account = account_fixture(features: %{idp_sync: true})
      admin_actor_fixture(account: account)

      directory =
        entra_directory_fixture(
          sync_error_attrs(account: account, error_email_count: 0, error_message: "enqueue fail")
        )

      log =
        capture_log(fn ->
          assert :ok = perform_job(SyncErrorNotification, notification_args("entra", "daily"))
        end)

      assert log =~ "Failed to enqueue sync error email"
      assert log =~ directory.id
      assert log =~ "injected_failure"
      assert Repo.get!(Portal.Entra.Directory, directory.id).error_email_count == 1
      refute_email_queued(account.id)
      assert collect_queued_emails(account.id) == []
    end

    test "returns an error for unknown providers" do
      assert {:error, "Unknown provider: ldap"} =
               perform_job(SyncErrorNotification, notification_args("ldap", "daily"))
    end
  end

  defp notification_args(provider, frequency) do
    %{
      "provider" => provider,
      "frequency" => frequency
    }
  end

  defp sync_error_attrs(attrs) do
    Enum.into(attrs, %{
      is_disabled: true,
      disabled_reason: "Sync error",
      is_verified: false,
      errored_at: DateTime.utc_now(),
      error_message: "sync failed",
      error_email_count: 0
    })
  end
end
