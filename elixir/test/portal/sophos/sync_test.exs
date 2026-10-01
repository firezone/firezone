defmodule Portal.Sophos.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.SophosFixtures
  import ExUnit.CaptureLog

  alias Portal.Sophos.{APIClient, Device, PostureProvider, Sync}

  # Every top-level property of the Endpoint object in the Endpoint API v1
  # spec 1.72.0: https://developer.sophos.com/assets/specs/endpoint-v1.yaml
  @endpoint_properties ~w[
    assignedProducts associatedPerson cloned cloud deviceSoftware encryption group
    groupHierarchy health hostname id ipv4Addresses ipv6Addresses isolation
    lastAgentUpdateAt lastOsUpdateAt lastSeenAt lockdown macAddresses online os packages
    serialNumber tags tamperProtectionEnabled tamperProtectionSupported tenant type
  ]

  setup do
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "notMocked"}) end)
    :ok
  end

  test "stores every property of the documented Endpoint object" do
    provider = sophos_posture_provider_fixture()
    endpoint = full_sophos_api_endpoint_fixture()

    assert length(@endpoint_properties) == 28
    assert MapSet.new(Map.keys(endpoint)) == MapSet.new(@endpoint_properties)
    assert MapSet.new(Sync.endpoint_properties()) == MapSet.new(@endpoint_properties)

    stub_endpoints([endpoint])

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, sophos_id: "7d0a1d3b-8a6f-4a55-9c1e-2f0b8e6c4d21")

    inventory_fields =
      Device.__schema__(:fields) --
        [:account_id, :posture_provider_id, :synced_at, :inserted_at, :updated_at]

    assert Enum.filter(inventory_fields, &is_nil(Map.fetch!(device, &1))) == []

    assert device.account_id == provider.account_id
    assert device.posture_provider_id == provider.id
    assert device.serial_number == "P28DA81LMD5T"
    assert device.sophos_tenant_id == "57ca9a6b-885f-4e36-95ec-290548c26059"
    assert device.health_overall == "suspicious"
    assert device.health_services_status == "suspicious"
    assert device.health_service_details == [%{"name" => "Sophos Endpoint Defense", "status" => "stopped"}]
    assert device.os_platform == "macOS"
    assert device.os_major_version == 15
    assert device.os_build == 1
    assert device.os_is_server == false
    assert device.associated_person_via_login == "jane"
    assert device.encryption_overall_status == "encrypted"
    assert device.encryption_volumes == [%{"volumeId" => "disk1s1", "status" => "encrypted"}]
    assert device.lockdown_status == "notInstalled"
    assert device.cloud_instance_id == "i-1234567890"
    assert device.isolation_status == "notIsolated"
    assert device.last_seen_at == ~U[2026-09-28 12:02:01.700000Z]
    assert device.mac_addresses == ["00:25:96:12:34:56"]
  end

  test "authenticates, pins the tenant, and follows nextKey through every page" do
    provider = sophos_posture_provider_fixture(client_id: "client-1", client_secret: "secret-1")
    test_pid = self()

    first_page = Enum.map(1..100, fn _n -> sophos_api_endpoint_fixture() end)
    last_page = [sophos_api_endpoint_fixture()]

    Req.Test.stub(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.host, conn.request_path} do
        {"id.sophos.com", "/api/v2/oauth2/token"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:token_request, URI.decode_query(body)})
          Req.Test.json(conn, %{"access_token" => "jwt-1", "expires_in" => 3600})

        {"api-us03.central.sophos.com", "/endpoint/v1/endpoints"} ->
          send(
            test_pid,
            {:page_request, conn.query_params, Plug.Conn.get_req_header(conn, "authorization"),
             Plug.Conn.get_req_header(conn, "x-tenant-id")}
          )

          case conn.query_params["pageFromKey"] do
            nil -> Req.Test.json(conn, %{"items" => first_page, "pages" => %{"nextKey" => "key-2", "size" => 100}})
            "key-2" -> Req.Test.json(conn, %{"items" => last_page, "pages" => %{"size" => 100}})
          end
      end
    end)

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 101

    assert_received {:token_request,
                     %{
                       "grant_type" => "client_credentials",
                       "client_id" => "client-1",
                       "client_secret" => "secret-1",
                       "scope" => "token"
                     }}

    tenant_id = provider.tenant_id

    assert_received {:page_request, %{"pageSize" => "100", "view" => "full"} = first_params, ["Bearer jwt-1"],
                     [^tenant_id]}

    refute Map.has_key?(first_params, "pageFromKey")

    assert_received {:page_request, %{"pageFromKey" => "key-2", "pageSize" => "100", "view" => "full"}, _auth,
                     [^tenant_id]}
  end

  test "raises when the credentials are rejected" do
    provider = sophos_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"errorCode" => "INVALID_CLIENT", "error" => "invalidClient"})
    end)

    error = assert_raise Portal.Sophos.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
    assert error.step == :get_access_token
    assert %Req.Response{status: 401} = error.error
  end

  test "raises rather than treating an invalid response as an empty tenant" do
    provider = sophos_posture_provider_fixture()

    stub_api(fn conn -> Req.Test.json(conn, %{"endpoints" => []}) end)

    error = assert_raise Portal.Sophos.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
    assert error.step == :list_endpoints
  end

  test "skips and warns about an endpoint without an id" do
    provider = sophos_posture_provider_fixture()
    valid = sophos_api_endpoint_fixture()
    invalid = sophos_api_endpoint_fixture(%{"id" => nil, "hostname" => "WORKSTATION-1"})

    stub_endpoints([invalid, valid])

    log = capture_log(fn -> perform_job(Sync, sync_args(provider)) end)

    assert Repo.get_by!(Device, account_id: provider.account_id, sophos_id: valid["id"])
    assert Repo.aggregate(Device, :count) == 1
    assert log =~ "Skipping Sophos endpoint without an id"
    assert log =~ "hostname=WORKSTATION-1"
  end

  test "deletes endpoints no completed run has seen for a day" do
    provider = sophos_posture_provider_fixture(synced_at: ago(2, :hour))
    stale = sophos_device_fixture(provider: provider, synced_at: ago(2, :day))
    stub_endpoints([sophos_api_endpoint_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    refute Repo.get_by(Device, account_id: provider.account_id, sophos_id: stale.sophos_id)
  end

  test "keeps an endpoint a single run skipped over" do
    provider = sophos_posture_provider_fixture(synced_at: ago(2, :hour))
    skipped = sophos_device_fixture(provider: provider, synced_at: ago(3, :hour))
    stub_endpoints([sophos_api_endpoint_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, sophos_id: skipped.sophos_id)
  end

  test "keeps an endpoint skipped by the first successful run after a long outage" do
    outage = ago(30, :day)
    provider = sophos_posture_provider_fixture(synced_at: outage)
    skipped = sophos_device_fixture(provider: provider, synced_at: outage)
    stub_endpoints([sophos_api_endpoint_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, sophos_id: skipped.sophos_id)
  end

  test "deletes nothing on a provider's first run" do
    provider = sophos_posture_provider_fixture(synced_at: nil)
    ancient = sophos_device_fixture(provider: provider, synced_at: ago(30, :day))
    stub_endpoints([sophos_api_endpoint_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by(Device, account_id: provider.account_id, sophos_id: ancient.sophos_id)
  end

  test "records success and clears earlier provider errors" do
    provider =
      sophos_posture_provider_fixture(
        errored_at: DateTime.utc_now(),
        error_message: "HTTP 503",
        error_email_count: 2
      )

    stub_endpoints([sophos_api_endpoint_fixture()])
    assert :ok = perform_job(Sync, sync_args(provider))

    provider = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  test "skips a disabled provider" do
    provider = sophos_posture_provider_fixture(is_disabled: true)
    stub_endpoints([sophos_api_endpoint_fixture()])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  defp sync_args(provider) do
    %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
  end

  defp ago(amount, unit) do
    DateTime.utc_now() |> DateTime.add(-amount, unit) |> DateTime.truncate(:microsecond)
  end

  defp stub_endpoints(endpoints) do
    stub_api(fn conn -> Req.Test.json(conn, %{"items" => endpoints, "pages" => %{"size" => 100}}) end)
  end

  defp stub_api(endpoints) do
    Req.Test.stub(APIClient, fn
      %{request_path: "/api/v2/oauth2/token"} = conn -> Req.Test.json(conn, %{"access_token" => "jwt"})
      conn -> endpoints.(conn)
    end)
  end
end
