defmodule Portal.GoogleEndpoint.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.GoogleEndpointFixtures
  import ExUnit.CaptureLog

  alias Portal.GoogleEndpoint.{APIClient, Device, PostureProvider, Sync}

  # Every top-level property of the Device resource in the Cloud Identity
  # API v1 reference: https://cloud.google.com/identity/docs/reference/rest/v1/devices
  @device_properties ~w[
    androidSpecificAttributes assetTag basebandVersion bootloaderVersion brand buildNumber
    compromisedState createTime deviceId deviceType enabledDeveloperOptions enabledUsbDebugging
    encryptionState endpointVerificationSpecificAttributes hostname imei kernelVersion
    lastSyncTime managementState manufacturer meid model name networkOperator osVersion
    otherAccounts ownerType releaseVersion securityPatchTime serialNumber unifiedDeviceId
    wifiMacAddresses
  ]

  setup do
    configure_google_endpoint_api_client()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "not mocked"}) end)
    :ok
  end

  test "stores every property of the documented Device resource" do
    provider = google_endpoint_posture_provider_fixture()
    device = full_google_endpoint_api_device_fixture()

    assert length(@device_properties) == 32
    assert MapSet.new(Map.keys(device)) == MapSet.new(@device_properties)
    assert MapSet.new(Sync.device_properties()) == MapSet.new(@device_properties)

    stub_devices([device])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, google_id: "ZXhhbXBsZS1kZXZpY2U")

    inventory_fields =
      Device.__schema__(:fields) --
        [:account_id, :posture_provider_id, :synced_at, :inserted_at, :updated_at]

    assert Enum.filter(inventory_fields, &is_nil(Map.fetch!(device, &1))) == []

    assert device.account_id == provider.account_id
    assert device.posture_provider_id == provider.id
    assert device.serial_number == "HT82V1A01076"
    assert device.device_type == "ANDROID"
    assert device.owner_type == "COMPANY"
    assert device.encryption_state == "ENCRYPTED"
    assert device.compromised_state == "UNCOMPROMISED"
    assert device.android_ownership_privilege == "DEVICE_OWNER"
    assert device.android_verified_boot == true
    assert device.android_has_potentially_harmful_apps == false
    assert device.wifi_mac_addresses == ["00:25:96:12:34:56"]
    assert device.registered_at == ~U[2026-01-15 10:00:00.123456Z]
    assert device.last_sync_at == ~U[2026-10-31 12:02:01.700000Z]
    assert device.security_patch_at == ~U[2026-10-05 00:00:00.000000Z]

    assert device.endpoint_verification_attributes == %{
             "additionalSignals" => %{"is_os_native_firewall_enabled" => true}
           }
  end

  test "acts as the verifying administrator and follows nextPageToken through every page" do
    provider = google_endpoint_posture_provider_fixture(impersonation_email: "admin@acme.com")
    test_pid = self()

    first_page = Enum.map(1..100, fn _n -> google_endpoint_api_device_fixture() end)
    last_page = [google_endpoint_api_device_fixture()]

    Req.Test.stub(Portal.Google.APIClient, fn %{request_path: "/token"} = conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "delegated-1", "expires_in" => 3600})
    end)

    Req.Test.stub(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        test_pid,
        {:page_request, conn.host, conn.request_path, conn.query_params,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      case conn.query_params["pageToken"] do
        nil -> Req.Test.json(conn, %{"devices" => first_page, "nextPageToken" => "token-2"})
        "token-2" -> Req.Test.json(conn, %{"devices" => last_page})
      end
    end)

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 101

    assert_received {:token_request, %{"assertion" => assertion}}
    [_header, payload, _signature] = String.split(assertion, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
    assert claims["sub"] == "admin@acme.com"
    assert claims["iss"] == "endpoint@test-project.iam.gserviceaccount.com"
    assert claims["scope"] == "https://www.googleapis.com/auth/cloud-identity.devices.readonly"

    assert_received {:page_request, "cloudidentity.googleapis.com", "/v1/devices", first_params,
                     ["Bearer delegated-1"]}

    assert first_params == %{
             "customer" => "customers/my_customer",
             "pageSize" => "100",
             "view" => "USER_ASSIGNED_DEVICES"
           }

    assert_received {:page_request, _host, _path, %{"pageToken" => "token-2"}, _auth}
  end

  test "reads a page without devices as an empty customer" do
    provider = google_endpoint_posture_provider_fixture()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{}) end)

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  test "raises when Google refuses the delegated token" do
    provider = google_endpoint_posture_provider_fixture()

    Req.Test.stub(Portal.Google.APIClient, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "unauthorized_client"})
    end)

    error =
      assert_raise Portal.GoogleEndpoint.SyncError, fn -> perform_job(Sync, sync_args(provider)) end

    assert error.step == :get_access_token
    assert %Req.Response{status: 401} = error.error
  end

  test "raises when the service account is not configured" do
    provider = google_endpoint_posture_provider_fixture()
    Portal.Config.put_env_override(:portal, APIClient, service_account_key: nil)

    error =
      assert_raise Portal.GoogleEndpoint.SyncError, fn -> perform_job(Sync, sync_args(provider)) end

    assert error.error == :service_account_not_configured
  end

  test "raises rather than treating an invalid response as an empty customer" do
    provider = google_endpoint_posture_provider_fixture()
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"devices" => "nope"}) end)

    error =
      assert_raise Portal.GoogleEndpoint.SyncError, fn -> perform_job(Sync, sync_args(provider)) end

    assert error.step == :list_devices
  end

  test "skips and warns about a device without a resource name" do
    provider = google_endpoint_posture_provider_fixture()
    valid = google_endpoint_api_device_fixture()
    invalid = google_endpoint_api_device_fixture(%{"name" => nil, "deviceType" => "IOS"})

    stub_devices([invalid, valid])

    log = capture_log(fn -> perform_job(Sync, sync_args(provider)) end)

    "devices/" <> google_id = valid["name"]
    assert Repo.get_by!(Device, account_id: provider.account_id, google_id: google_id)
    assert Repo.aggregate(Device, :count) == 1
    assert log =~ "Skipping Google Endpoint device without a resource name"
    assert log =~ "device_type=IOS"
  end

  test "deletes devices no completed run has seen for a day" do
    provider = google_endpoint_posture_provider_fixture(synced_at: ago(2, :hour))
    stale = google_endpoint_device_fixture(provider: provider, synced_at: ago(2, :day))
    stub_devices([google_endpoint_api_device_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    refute Repo.get_by(Device, account_id: provider.account_id, google_id: stale.google_id)
  end

  test "keeps a device a single run skipped over" do
    provider = google_endpoint_posture_provider_fixture(synced_at: ago(2, :hour))
    skipped = google_endpoint_device_fixture(provider: provider, synced_at: ago(3, :hour))
    stub_devices([google_endpoint_api_device_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, google_id: skipped.google_id)
  end

  test "deletes nothing on a provider's first run" do
    provider = google_endpoint_posture_provider_fixture(synced_at: nil)
    ancient = google_endpoint_device_fixture(provider: provider, synced_at: ago(30, :day))
    stub_devices([google_endpoint_api_device_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, google_id: ancient.google_id)
  end

  test "records success and clears earlier provider errors" do
    provider =
      google_endpoint_posture_provider_fixture(
        errored_at: DateTime.utc_now(),
        error_message: "HTTP 503",
        error_email_count: 2
      )

    stub_devices([google_endpoint_api_device_fixture()])
    assert :ok = perform_job(Sync, sync_args(provider))

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  test "skips a disabled provider" do
    provider = google_endpoint_posture_provider_fixture(is_disabled: true)
    stub_devices([google_endpoint_api_device_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  defp sync_args(provider) do
    %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
  end

  defp ago(amount, unit) do
    DateTime.utc_now() |> DateTime.add(-amount, unit) |> DateTime.truncate(:microsecond)
  end

  defp stub_devices(devices) do
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"devices" => devices}) end)
  end
end
