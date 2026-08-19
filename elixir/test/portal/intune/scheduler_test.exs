defmodule Portal.Intune.SchedulerTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures

  alias Portal.Intune.{Scheduler, Sync}

  setup do
    enable_device_posture()
    :ok
  end

  test "enqueues a sync job for each enabled and verified provider" do
    first = intune_posture_provider_fixture()
    second = intune_posture_provider_fixture()

    perform_job(Scheduler, %{})

    jobs = all_enqueued(worker: Sync)
    assert length(jobs) == 2
    assert first.id in Enum.map(jobs, & &1.args["posture_provider_id"])
    assert second.id in Enum.map(jobs, & &1.args["posture_provider_id"])

    assert hd(jobs).queue == "intune_sync"
  end

  test "skips disabled, unverified, and disabled-account providers" do
    intune_posture_provider_fixture(is_disabled: true)
    intune_posture_provider_fixture(is_verified: false)

    disabled_account =
      account_fixture()
      |> Ecto.Changeset.change(is_disabled: true)
      |> Repo.update!()

    intune_posture_provider_fixture(account: disabled_account)

    enabled = intune_posture_provider_fixture()

    perform_job(Scheduler, %{})

    assert [job] = all_enqueued(worker: Sync)
    assert job.args["posture_provider_id"] == enabled.id
    assert job.args["account_id"] == enabled.account_id
  end

  test "skips providers whose account lost the device_posture feature" do
    downgraded = account_fixture(features: %{device_posture: false})
    intune_posture_provider_fixture(account: downgraded)

    enabled = intune_posture_provider_fixture()

    perform_job(Scheduler, %{})

    assert [job] = all_enqueued(worker: Sync)
    assert job.args["posture_provider_id"] == enabled.id
  end

  test "queues nothing when the global device_posture flag is off" do
    enable_device_posture(false)
    intune_posture_provider_fixture()

    assert {:ok, :skipped} = perform_job(Scheduler, %{})

    assert all_enqueued(worker: Sync) == []
  end
end
