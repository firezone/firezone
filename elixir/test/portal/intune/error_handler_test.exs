defmodule Portal.Intune.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import Portal.IntuneFixtures

  alias Portal.Intune.{ErrorHandler, Integration, SyncError}

  test "disables and unverifies the integration when Microsoft Graph denies access" do
    integration = intune_integration_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 403, body: ""}), integration.id)

    integration = Repo.get_by!(Integration, account_id: integration.account_id, id: integration.id)
    assert integration.is_disabled
    assert integration.disabled_reason == "Sync error"
    refute integration.is_verified
    assert integration.errored_at
    assert integration.error_message =~ "DeviceManagementManagedDevices.Read.All"
  end

  test "records a transient error without disabling the integration" do
    integration = intune_integration_fixture()

    ErrorHandler.handle(sync_error(%Req.TransportError{reason: :timeout}), integration.id)

    integration = Repo.get_by!(Integration, account_id: integration.account_id, id: integration.id)
    refute integration.is_disabled
    assert integration.is_verified
    assert integration.errored_at
    assert integration.error_message == "Connection timed out."
  end

  test "keeps the first errored_at so the transient window is measured from it" do
    first_errored_at = DateTime.utc_now() |> DateTime.add(-1, :hour)
    integration = intune_integration_fixture(errored_at: first_errored_at)

    ErrorHandler.handle(sync_error(%Req.Response{status: 503, body: ""}), integration.id)

    integration = Repo.get_by!(Integration, account_id: integration.account_id, id: integration.id)
    refute integration.is_disabled
    assert DateTime.compare(integration.errored_at, first_errored_at) == :eq
  end

  test "disables the integration once transient errors have persisted for a day" do
    integration =
      intune_integration_fixture(errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour))

    ErrorHandler.handle(sync_error(%Req.Response{status: 503, body: ""}), integration.id)

    integration = Repo.get_by!(Integration, account_id: integration.account_id, id: integration.id)
    assert integration.is_disabled
    refute integration.is_verified
  end

  test "handles an unknown integration id without raising" do
    assert :ok = ErrorHandler.handle(sync_error(:missing_device_id), Ecto.UUID.generate())
  end

  defp sync_error(error) do
    SyncError.exception(integration_id: Ecto.UUID.generate(), step: :list_managed_devices, error: error)
  end
end
