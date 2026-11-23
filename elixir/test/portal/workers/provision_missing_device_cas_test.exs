defmodule Portal.Workers.ProvisionMissingDeviceCAsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import Portal.AccountFixtures

  alias Portal.Workers.{ProvisionDeviceCA, ProvisionMissingDeviceCAs}

  test "queues the CA of each account without one, disabled or not" do
    enabled = account_fixture()
    disabled = disabled_account_fixture()
    with_ca = account_fixture()
    {:ok, _ca} = Portal.DeviceCA.ensure(with_ca.id)

    assert :ok = perform_job(ProvisionMissingDeviceCAs, %{})

    assert_enqueued(worker: ProvisionDeviceCA, args: %{account_id: enabled.id})
    assert_enqueued(worker: ProvisionDeviceCA, args: %{account_id: disabled.id})
    refute_enqueued(worker: ProvisionDeviceCA, args: %{account_id: with_ca.id})
  end
end
