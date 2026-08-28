defmodule Portal.SentinelOne.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import Portal.SentinelOneFixtures

  alias Portal.SentinelOne.{ErrorHandler, PostureProvider, SyncError}

  test "disables and unverifies the provider when SentinelOne denies access" do
    provider = sentinelone_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 403, body: %{}}), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    refute provider.is_verified
    assert provider.errored_at
    assert provider.error_message =~ "denied access"
  end

  test "reports SentinelOne's error details" do
    provider = sentinelone_posture_provider_fixture()

    response = %Req.Response{
      status: 403,
      body: %{"errors" => [%{"title" => "Insufficient user permissions"}]}
    }

    ErrorHandler.handle(sync_error(response), provider.id)
    assert reload(provider).error_message =~ "Insufficient user permissions"
  end

  test "does not disable the provider when SentinelOne throttles the tenant" do
    provider = sentinelone_posture_provider_fixture()

    ErrorHandler.handle(sync_error(%Req.Response{status: 429, body: %{}}), provider.id)

    provider = reload(provider)
    refute provider.is_disabled
    assert provider.is_verified
    assert provider.errored_at
  end

  test "disables the provider once a transient error has lasted a day" do
    provider =
      sentinelone_posture_provider_fixture(
        errored_at: DateTime.utc_now() |> DateTime.add(-25, :hour)
      )

    ErrorHandler.handle(sync_error(%Req.TransportError{reason: :timeout}), provider.id)

    provider = reload(provider)
    assert provider.is_disabled
    assert provider.disabled_reason == "Sync error"
    assert provider.error_message =~ "Connection timed out"
  end

  test "ignores an error for a provider that no longer exists" do
    assert :ok = ErrorHandler.handle(sync_error(:missing_agent_uuid), Ecto.UUID.generate())
  end

  defp reload(provider) do
    Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
  end

  defp sync_error(error) do
    SyncError.exception(provider_id: Ecto.UUID.generate(), step: :list_agents, error: error)
  end
end
