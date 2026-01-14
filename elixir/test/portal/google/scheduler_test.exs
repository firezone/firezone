defmodule Portal.Google.SchedulerTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures

  alias Portal.Google.Scheduler
  alias Portal.Google.Sync

  describe "perform/1" do
    test "schedules sync jobs for enabled directories with idp_sync feature" do
      # Create an account with idp_sync feature enabled
      account = account_fixture(features: %{idp_sync: true})

      # Create multiple Google directories for this account
      dir1 = google_directory_fixture(account: account, name: "Directory 1")
      dir2 = google_directory_fixture(account: account, name: "Directory 2")

      # Perform the scheduler job
      perform_job(Scheduler, %{})

      # Verify sync jobs were created for both directories
      jobs = all_enqueued(worker: Sync)
      assert length(jobs) == 2

      job_directory_ids = Enum.map(jobs, & &1.args["directory_id"])
      assert dir1.id in job_directory_ids
      assert dir2.id in job_directory_ids
    end

    test "does not schedule jobs for disabled directories" do
      account = account_fixture(features: %{idp_sync: true})

      # Create a disabled directory
      _disabled_dir =
        google_directory_fixture(
          account: account,
          name: "Disabled Directory",
          is_disabled: true
        )

      # Create an enabled directory
      enabled_dir = google_directory_fixture(account: account, name: "Enabled Directory")

      perform_job(Scheduler, %{})

      # Only the enabled directory should have a sync job
      jobs = all_enqueued(worker: Sync)
      assert length(jobs) == 1
      assert hd(jobs).args["directory_id"] == enabled_dir.id
    end

    test "does not schedule jobs for directories with disabled accounts" do
      # Create a disabled account
      disabled_account = account_fixture(features: %{idp_sync: true})

      # Disable the account
      disabled_account =
        disabled_account
        |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
        |> Repo.update!()

      _dir = google_directory_fixture(account: disabled_account, name: "Directory")

      # Create an enabled account with a directory
      enabled_account = account_fixture(features: %{idp_sync: true})
      enabled_dir = google_directory_fixture(account: enabled_account, name: "Enabled Directory")

      perform_job(Scheduler, %{})

      # Only the directory from the enabled account should have a sync job
      jobs = all_enqueued(worker: Sync)
      assert length(jobs) == 1
      assert hd(jobs).args["directory_id"] == enabled_dir.id
    end

    test "does not schedule jobs for accounts without idp_sync feature" do
      # Account without idp_sync feature
      account_without_feature = account_fixture(features: %{})
      _dir = google_directory_fixture(account: account_without_feature, name: "Directory")

      # Account with idp_sync feature
      account_with_feature = account_fixture(features: %{idp_sync: true})

      enabled_dir =
        google_directory_fixture(account: account_with_feature, name: "Enabled Directory")

      perform_job(Scheduler, %{})

      # Only the directory from the account with the feature should have a sync job
      jobs = all_enqueued(worker: Sync)
      assert length(jobs) == 1
      assert hd(jobs).args["directory_id"] == enabled_dir.id
    end

    test "handles empty directory list gracefully" do
      # Don't create any directories
      perform_job(Scheduler, %{})

      # No sync jobs should be created
      jobs = all_enqueued(worker: Sync)
      assert jobs == []
    end

    test "creates jobs with correct structure" do
      account = account_fixture(features: %{idp_sync: true})
      directory = google_directory_fixture(account: account)

      perform_job(Scheduler, %{})

      jobs = all_enqueued(worker: Sync)
      assert [job] = jobs

      # Verify job structure
      assert job.worker == "Portal.Google.Sync"
      assert job.queue == "google_sync"
      assert job.args == %{"directory_id" => directory.id}
    end

    test "schedules multiple jobs for multiple accounts" do
      # Create multiple accounts with directories
      account1 = account_fixture(features: %{idp_sync: true})
      account2 = account_fixture(features: %{idp_sync: true})

      dir1 = google_directory_fixture(account: account1, name: "Account 1 Directory")
      dir2 = google_directory_fixture(account: account2, name: "Account 2 Directory")

      perform_job(Scheduler, %{})

      jobs = all_enqueued(worker: Sync)
      assert length(jobs) == 2

      job_directory_ids = Enum.map(jobs, & &1.args["directory_id"])
      assert dir1.id in job_directory_ids
      assert dir2.id in job_directory_ids
    end
  end
end
