defmodule Portal.GoogleEndpoint.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import Portal.GoogleEndpointFixtures

  alias Portal.GoogleEndpoint.{ErrorHandler, PostureProvider, SyncError}

  test "disables and unverifies the provider when delegation is revoked" do
    provider = google_endpoint_posture_provider_fixture()

    response = %Req.Response{status: 401, body: %{"error" => "unauthorized_client"}}
    assert :disabled = ErrorHandler.handle(sync_error(response), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    refute provider.is_verified
    assert provider.error_message =~ "domain-wide delegation"
    assert provider.error_message =~ "cloud-identity.devices.readonly"
  end

  test "disables the provider when Google refuses to act as the administrator" do
    provider = google_endpoint_posture_provider_fixture()

    response = %Req.Response{
      status: 400,
      body: %{"error" => "invalid_grant", "error_description" => "Invalid email or User ID"}
    }

    ErrorHandler.handle(sync_error(response), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.error_message =~ "Invalid email or User ID"
  end

  test "disables the provider when the administrator cannot read devices" do
    provider = google_endpoint_posture_provider_fixture()

    response = %Req.Response{
      status: 403,
      body: %{"error" => %{"code" => 403, "message" => "Not Authorized to access this resource/api"}}
    }

    ErrorHandler.handle(sync_error(response), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.error_message =~ "can still manage devices"
  end

  test "reports Google's error message" do
    provider = google_endpoint_posture_provider_fixture()

    response = %Req.Response{
      status: 400,
      body: %{"error" => %{"code" => 400, "message" => "Request contains an invalid argument."}}
    }

    ErrorHandler.handle(sync_error(response), provider.id)
    assert reload(provider).error_message == "HTTP 400 - Request contains an invalid argument."
  end

  test "does not disable the provider when Firezone's own federation fails" do
    provider = google_endpoint_posture_provider_fixture()

    error = {:service_account_sign_jwt, %Req.Response{status: 403, body: %{}}}
    assert :ok = ErrorHandler.handle(sync_error(error), provider.id)

    provider = reload(provider)
    refute provider.is_disabled
    assert provider.is_verified
    assert provider.error_message =~ "could not authenticate"
  end

  test "does not disable the provider when Google rate limits it" do
    provider = google_endpoint_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 429, body: %{}}), provider.id)

    provider = reload(provider)
    refute provider.is_disabled
    assert provider.errored_at
  end

  test "disables the provider once a transient error has lasted a day" do
    provider =
      google_endpoint_posture_provider_fixture(
        errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour)
      )

    ErrorHandler.handle(sync_error(%Req.TransportError{reason: :timeout}), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.error_message =~ "Connection timed out"
  end

  test "ignores an error for a provider that no longer exists" do
    assert :ok = ErrorHandler.handle(sync_error(:timeout), Ecto.UUID.generate())
  end

  defp reload(provider) do
    Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
  end

  defp sync_error(error) do
    SyncError.exception(provider_id: Ecto.UUID.generate(), step: :list_devices, error: error)
  end
end
