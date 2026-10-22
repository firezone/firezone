defmodule Portal.Sophos.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import Portal.SophosFixtures

  alias Portal.Sophos.{ErrorHandler, PostureProvider, SyncError}

  test "disables and unverifies the provider when Sophos denies access" do
    provider = sophos_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 401, body: %{"error" => "Unauthorized"}}), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    refute provider.is_verified
    assert provider.errored_at
    assert provider.error_message =~ "denied access"
  end

  test "reports Sophos's error message" do
    provider = sophos_posture_provider_fixture()

    response = %Req.Response{
      status: 400,
      body: %{"error" => "badRequest", "message" => "Invalid page key"}
    }

    ErrorHandler.handle(sync_error(response), provider.id)
    assert reload(provider).error_message == "HTTP 400 - Invalid page key"
  end

  test "disables the provider for credentials that are not a tenant's" do
    provider = sophos_posture_provider_fixture()

    ErrorHandler.handle(sync_error(:unsupported_credentials), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.error_message =~ "do not belong to a single tenant"
  end

  test "does not disable the provider when Sophos rate limits it" do
    provider = sophos_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 429, body: %{}}), provider.id)

    provider = reload(provider)
    refute provider.is_disabled
    assert provider.is_verified
    assert provider.errored_at
  end

  test "disables the provider once a transient error has lasted a day" do
    provider =
      sophos_posture_provider_fixture(errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour))

    ErrorHandler.handle(sync_error(%Req.TransportError{reason: :timeout}), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    assert provider.error_message =~ "Connection timed out"
  end

  test "ignores an error for a provider that no longer exists" do
    assert :ok = ErrorHandler.handle(sync_error(:unsupported_credentials), Ecto.UUID.generate())
  end

  defp reload(provider) do
    Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
  end

  defp sync_error(error) do
    SyncError.exception(provider_id: Ecto.UUID.generate(), step: :list_endpoints, error: error)
  end
end
