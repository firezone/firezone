defmodule PortalAPI.GoogleEndpointDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.GoogleEndpointFixtures

  setup do
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = google_endpoint_posture_provider_fixture(account: account)

    device =
      google_endpoint_device_fixture(
        provider: provider,
        hostname: "production-mac",
        serial_number: "P28DA81LMD5T",
        encryption_state: "ENCRYPTED"
      )

    %{account: account, actor: actor, provider: provider, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = google_endpoint_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/google_endpoint_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"google_id" => google_id}] = response["data"]
    assert google_id == device.google_id
    refute google_id == other.google_id
  end

  test "show returns the endpoint", %{conn: conn, actor: actor, device: device} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/google_endpoint_devices/#{device.google_id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["hostname"] == "production-mac"
    assert data["serial_number"] == "P28DA81LMD5T"
    assert data["encryption_state"] == "ENCRYPTED"
  end

  test "show does not return another account's endpoint", %{conn: conn, actor: actor} do
    other = google_endpoint_device_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/google_endpoint_devices/#{other.google_id}")
           |> json_response(404)
  end

  test "is forbidden when the account feature is off", %{conn: conn, actor: actor, account: account} do
    disable_device_posture(account)

    response = conn |> authorize_conn(actor) |> get("/google_endpoint_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/google_endpoint_devices/#{device.google_id}") |> json_response(401)
  end
end
