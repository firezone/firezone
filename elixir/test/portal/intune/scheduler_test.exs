defmodule Portal.Intune.SchedulerTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.IntuneFixtures

  alias Portal.Intune.{Scheduler, Sync}

  test "enqueues a sync job for each enabled and verified integration" do
    first = intune_integration_fixture()
    second = intune_integration_fixture()

    perform_job(Scheduler, %{})

    jobs = all_enqueued(worker: Sync)
    assert length(jobs) == 2
    assert first.id in Enum.map(jobs, & &1.args["device_integration_id"])
    assert second.id in Enum.map(jobs, & &1.args["device_integration_id"])

    assert hd(jobs).queue == "intune_sync"
  end

  test "skips disabled, unverified, and disabled-account integrations" do
    intune_integration_fixture(is_disabled: true)
    intune_integration_fixture(is_verified: false)

    disabled_account =
      account_fixture()
      |> Ecto.Changeset.change(is_disabled: true)
      |> Repo.update!()

    intune_integration_fixture(account: disabled_account)

    enabled = intune_integration_fixture()

    perform_job(Scheduler, %{})

    assert [job] = all_enqueued(worker: Sync)
    assert job.args["device_integration_id"] == enabled.id
    assert job.args["account_id"] == enabled.account_id
  end
end
