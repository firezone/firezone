defmodule Portal.Santa.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import Portal.SantaFixtures

  alias Portal.Santa.{ErrorHandler, PostureProvider, SyncError}

  test "disables and unverifies a provider when Workshop rejects the key" do
    provider = santa_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 401, body: ""}), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    refute provider.is_verified
    assert provider.errored_at
    assert provider.error_message =~ "Authentication failed"
  end

  test "explains missing host permissions and an invalid tenant URL" do
    forbidden = santa_posture_provider_fixture()
    missing = santa_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 403, body: ""}), forbidden.id)
    ErrorHandler.handle(sync_error(%Req.Response{status: 404, body: ""}), missing.id)

    assert reload(forbidden).error_message =~ "permission to read hosts"
    assert reload(missing).error_message =~ "Workshop API URL"
  end

  test "waits a day before disabling a provider for transient errors" do
    recent = santa_posture_provider_fixture()

    old =
      santa_posture_provider_fixture(
        errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour)
      )

    ErrorHandler.handle(sync_error(%Req.Response{status: 429, body: ""}), recent.id)
    ErrorHandler.handle(sync_error(%Req.TransportError{reason: :timeout}), old.id)

    refute reload(recent).is_disabled
    assert reload(old).is_disabled
    assert reload(old).error_message =~ "Connection timed out"
  end

  test "ignores an error for a provider that no longer exists" do
    assert :ok = ErrorHandler.handle(sync_error(:missing_host_id), Ecto.UUID.generate())
  end

  defp reload(provider) do
    Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
  end

  defp sync_error(error) do
    SyncError.exception(provider_id: Ecto.UUID.generate(), step: :list_hosts, error: error)
  end
end
