defmodule Portal.Santa.SchedulerTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.DevicePostureFixtures
  import Portal.SantaFixtures

  alias Portal.Santa.{Scheduler, Sync}

  setup do
    enable_device_posture()
    :ok
  end

  test "enqueues each enabled and verified provider" do
    first = santa_posture_provider_fixture()
    second = santa_posture_provider_fixture()

    perform_job(Scheduler, %{})

    jobs = all_enqueued(worker: Sync)
    assert length(jobs) == 2
    assert first.id in Enum.map(jobs, & &1.args["posture_provider_id"])
    assert second.id in Enum.map(jobs, & &1.args["posture_provider_id"])
    assert hd(jobs).queue == "santa_sync"
  end

  test "skips disabled, unverified, disabled-account, and downgraded providers" do
    santa_posture_provider_fixture(is_disabled: true)
    santa_posture_provider_fixture(is_verified: false)

    disabled_account =
      account_fixture()
      |> Ecto.Changeset.change(is_disabled: true)
      |> Repo.update!()

    santa_posture_provider_fixture(account: disabled_account)
    santa_posture_provider_fixture(account: account_fixture(features: %{device_posture: false}))
    enabled = santa_posture_provider_fixture()

    perform_job(Scheduler, %{})

    assert [job] = all_enqueued(worker: Sync)
    assert job.args["posture_provider_id"] == enabled.id
    assert job.args["account_id"] == enabled.account_id
  end

  test "queues nothing when the global flag is off" do
    enable_device_posture(false)
    santa_posture_provider_fixture()

    assert {:ok, :skipped} = perform_job(Scheduler, %{})
    assert all_enqueued(worker: Sync) == []
  end
end
