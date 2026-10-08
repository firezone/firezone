defmodule Portal.Intune.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import Portal.IntuneFixtures

  alias Portal.Intune.{ErrorHandler, PostureProvider, SyncError}

  test "disables and unverifies a previously synced provider when Microsoft Graph denies access" do
    provider = intune_posture_provider_fixture(synced_at: DateTime.utc_now() |> DateTime.add(-2, :hour))

    ErrorHandler.handle(sync_error(%Req.Response{status: 403, body: ""}), provider.id)

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    refute provider.is_verified
    assert provider.errored_at
    assert provider.error_message =~ "DeviceManagementManagedDevices.Read.All"
  end

  test "keeps a never-synced provider enabled while admin consent propagates" do
    for status <- [401, 403] do
      provider = intune_posture_provider_fixture()

      assert :ok = ErrorHandler.handle(sync_error(intune_forbidden_response(status)), provider.id)

      provider =
        Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)

      refute provider.is_disabled
      assert provider.is_verified
      assert provider.errored_at
      assert provider.error_message =~ "can take up to 30 minutes to take effect"
    end
  end

  test "disables a never-synced provider once access has been denied for a day" do
    provider =
      intune_posture_provider_fixture(errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour))

    assert :disabled = ErrorHandler.handle(sync_error(intune_forbidden_response(401)), provider.id)

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.is_disabled
    refute provider.is_verified
  end

  test "disables a never-synced provider when the token endpoint rejects it" do
    provider = intune_posture_provider_fixture()

    response = %Req.Response{
      status: 401,
      body: %{"error" => "invalid_client", "error_description" => "AADSTS7000215: Invalid client secret."}
    }

    assert :disabled = ErrorHandler.handle(sync_error(response, :get_access_token), provider.id)

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.is_disabled
    assert provider.error_message =~ "AADSTS7000215"
  end

  test "does not disable the provider when Microsoft Graph throttles the tenant" do
    for status <- [408, 429] do
      provider = intune_posture_provider_fixture()

      ErrorHandler.handle(
        sync_error(%Req.Response{status: status, body: %{"error" => %{"code" => "TooManyRequests"}}}),
        provider.id
      )

      provider =
        Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)

      refute provider.is_disabled
      assert provider.is_verified
      assert provider.errored_at
    end
  end

  test "records a transient error without disabling the provider" do
    provider = intune_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.TransportError{reason: :timeout}), provider.id)

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    refute provider.is_disabled
    assert provider.is_verified
    assert provider.errored_at
    assert provider.error_message == "Connection timed out."
  end

  test "keeps the first errored_at so the transient window is measured from it" do
    first_errored_at = DateTime.utc_now() |> DateTime.add(-1, :hour)
    provider = intune_posture_provider_fixture(errored_at: first_errored_at)

    ErrorHandler.handle(sync_error(%Req.Response{status: 503, body: ""}), provider.id)

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    refute provider.is_disabled
    assert DateTime.compare(provider.errored_at, first_errored_at) == :eq
  end

  test "disables the provider once transient errors have persisted for a day" do
    provider =
      intune_posture_provider_fixture(errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour))

    ErrorHandler.handle(sync_error(%Req.Response{status: 503, body: ""}), provider.id)

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.is_disabled
    refute provider.is_verified
  end

  test "handles an unknown provider id without raising" do
    assert :ok = ErrorHandler.handle(sync_error(:missing_device_id), Ecto.UUID.generate())
  end

  defp sync_error(error, step \\ :list_managed_devices) do
    SyncError.exception(provider_id: Ecto.UUID.generate(), step: step, error: error)
  end

  # The shape Intune returns while a fresh grant has not taken effect yet.
  defp intune_forbidden_response(status) do
    %Req.Response{
      status: status,
      body: %{
        "error" => %{
          "code" => "UnknownError",
          "message" => ~s({"ErrorCode":"Forbidden","Message":"An error has occurred"})
        }
      }
    }
  end
end
