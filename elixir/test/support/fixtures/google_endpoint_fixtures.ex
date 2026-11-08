defmodule Portal.GoogleEndpointFixtures do
  @moduledoc "Test helpers for Google Endpoint Management posture providers and devices."

  import Portal.DevicePostureFixtures

  @token_path "/token"

  def google_endpoint_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Google Endpoint #{unique}")
    parent = posture_provider_fixture(account, id, :google_endpoint, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      impersonation_email: Map.get(attrs, :impersonation_email, "admin-#{unique}@example.com"),
      domain: Map.get(attrs, :domain, "example-#{unique}.com"),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.GoogleEndpoint.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.GoogleEndpoint.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def google_endpoint_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || google_endpoint_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      google_id: Map.get(attrs, :google_id, "device-#{unique}"),
      hostname: Map.get(attrs, :hostname, "laptop-#{unique}"),
      serial_number: Map.get(attrs, :serial_number, "GOOGLE-SERIAL-#{unique}"),
      device_type: Map.get(attrs, :device_type, "MAC_OS"),
      owner_type: Map.get(attrs, :owner_type, "COMPANY"),
      management_state: Map.get(attrs, :management_state, "APPROVED"),
      encryption_state: Map.get(attrs, :encryption_state, "ENCRYPTED"),
      compromised_state: Map.get(attrs, :compromised_state),
      os_version: Map.get(attrs, :os_version, "MacOS 15.6.1"),
      security_patch_at: Map.get(attrs, :security_patch_at),
      last_sync_at: Map.get(attrs, :last_sync_at),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.GoogleEndpoint.Device{}
    |> Portal.GoogleEndpoint.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end

  @doc """
  Gives the Google Endpoint service account a key, so its delegated tokens
  come from the stubbed `Portal.Google.APIClient` token endpoint.
  """
  def configure_google_endpoint_api_client do
    Portal.Config.put_env_override(:portal, Portal.GoogleEndpoint.APIClient,
      service_account_key:
        Portal.GoogleAPIClientHelpers.service_account_key_json(
          "endpoint@test-project.iam.gserviceaccount.com"
        )
    )

    Portal.Config.put_env_override(:portal, Portal.Google.APIClient,
      token_endpoint: "https://oauth2.googleapis.com#{@token_path}"
    )

    stub_google_endpoint_token("google-endpoint-token")
    :ok
  end

  @doc "Answers every delegated token request with `token`."
  def stub_google_endpoint_token(token) do
    Req.Test.stub(Portal.Google.APIClient, fn
      %{request_path: @token_path} = conn ->
        Req.Test.json(conn, %{"access_token" => token, "expires_in" => 3600})

      conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
    end)
  end

  @doc "A minimal Devices API device for sync tests."
  def google_endpoint_api_device_fixture(overrides \\ %{}) do
    unique = System.unique_integer([:positive, :monotonic])

    Map.merge(
      %{
        "name" => "devices/device-#{unique}",
        "deviceType" => "MAC_OS",
        "serialNumber" => "C02-#{unique}",
        "osVersion" => "MacOS 15.6.1"
      },
      Enum.into(overrides, %{})
    )
  end

  @doc """
  Every top-level property of the Device resource in the Cloud Identity API
  v1 reference, as `GET /v1/devices` returns it.
  """
  def full_google_endpoint_api_device_fixture do
    %{
      "name" => "devices/ZXhhbXBsZS1kZXZpY2U",
      "createTime" => "2026-01-15T10:00:00.123456789Z",
      "lastSyncTime" => "2026-10-31T12:02:01.700Z",
      "ownerType" => "COMPANY",
      "model" => "Pixel 9",
      "osVersion" => "Android 15",
      "deviceType" => "ANDROID",
      "serialNumber" => "HT82V1A01076",
      "assetTag" => "ASSET-42",
      "imei" => "490154203237518",
      "meid" => "A0000000000001",
      "wifiMacAddresses" => ["00:25:96:12:34:56"],
      "networkOperator" => "Example Mobile",
      "manufacturer" => "Google",
      "releaseVersion" => "15",
      "brand" => "google",
      "buildNumber" => "AP4A.250105.002",
      "kernelVersion" => "6.1.75",
      "basebandVersion" => "g5300q-240308",
      "enabledDeveloperOptions" => false,
      "otherAccounts" => ["jane@example.com"],
      "enabledUsbDebugging" => false,
      "securityPatchTime" => "2026-10-05T00:00:00Z",
      "bootloaderVersion" => "ripcurrent-15.0",
      "encryptionState" => "ENCRYPTED",
      "androidSpecificAttributes" => %{
        "enabledUnknownSources" => false,
        "supportsWorkProfile" => true,
        "ownerProfileAccount" => true,
        "ownershipPrivilege" => "DEVICE_OWNER",
        "verifiedBoot" => true,
        "ctsProfileMatch" => true,
        "verifyAppsEnabled" => true,
        "hasPotentiallyHarmfulApps" => false
      },
      "managementState" => "APPROVED",
      "compromisedState" => "UNCOMPROMISED",
      "deviceId" => "a1b2c3d4",
      "unifiedDeviceId" => "u-a1b2c3d4",
      "endpointVerificationSpecificAttributes" => %{
        "additionalSignals" => %{"is_os_native_firewall_enabled" => true}
      },
      "hostname" => "janes-pixel"
    }
  end
end
