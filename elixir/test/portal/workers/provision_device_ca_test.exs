defmodule Portal.Workers.ProvisionDeviceCATest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import Portal.AccountFixtures

  alias Portal.Workers.{DeleteDeviceCA, ProvisionDeviceCA}

  test "creates the CA of the account" do
    account = account_fixture()

    assert :ok = perform_job(ProvisionDeviceCA, %{account_id: account.id})
    assert Repo.get_by(Portal.DeviceCertificateAuthority, account_id: account.id)
  end

  test "cancels for a deleted account" do
    assert {:cancel, :account_deleted} = perform_job(ProvisionDeviceCA, %{account_id: Ecto.UUID.generate()})
  end

  test "deletes the key of a deleted account" do
    assert :ok = perform_job(DeleteDeviceCA, %{account_id: Ecto.UUID.generate()})
  end
end
