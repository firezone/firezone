defmodule PortalAPI.IntuneDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = intune_posture_provider_fixture(account: account)

    device =
      intune_device_fixture(
        provider: provider,
        device_name: "Managed Surface",
        compliance_state: "compliant",
        operating_system: "Windows"
      )

    %{account: account, actor: actor, provider: provider, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = intune_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/intune_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"intune_id" => id}] = response["data"]
    assert id == device.intune_id
    refute id == other.intune_id
  end

  # Pagination.params_to_list_opts/1 returns {:ok, opts} | {:error, ...}
  # so a bad limit is a 400 rather than reaching the query. This endpoint
  # arrived while that contract was changing and briefly used the older
  # bare-keyword-list shape, which passed the tuple straight into
  # Safe.list/3 and raised.
  test "returns bad request for a non-integer limit", %{conn: conn, actor: actor} do
    response =
      conn
      |> authorize_conn(actor)
      |> get("/intune_devices", limit: "not-a-number")
      |> json_response(400)

    assert response["status"] == 400
  end

  test "show returns the provider fields", %{conn: conn, actor: actor, device: device} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_devices/#{device.intune_id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["device_name"] == "Managed Surface"
    assert data["compliance_state"] == "compliant"
    assert data["operating_system"] == "Windows"
  end

  test "is forbidden when the global flag is off", %{conn: conn, actor: actor} do
    enable_device_posture(false)

    response = conn |> authorize_conn(actor) |> get("/intune_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "is forbidden when the account flag is off", %{conn: conn} do
    account = Portal.AccountFixtures.account_fixture()
    actor = Portal.ActorFixtures.api_client_fixture(account: account)

    response = conn |> authorize_conn(actor) |> get("/intune_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/intune_devices/#{device.intune_id}") |> json_response(401)
  end
end
