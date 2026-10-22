defmodule PortalAPI.SophosDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.SophosFixtures

  setup do
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = sophos_posture_provider_fixture(account: account)

    device =
      sophos_device_fixture(
        provider: provider,
        hostname: "production-mac",
        serial_number: "P28DA81LMD5T",
        health_overall: "good"
      )

    %{account: account, actor: actor, provider: provider, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = sophos_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/sophos_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"sophos_id" => sophos_id}] = response["data"]
    assert sophos_id == device.sophos_id
    refute sophos_id == other.sophos_id
  end

  test "show returns the endpoint", %{conn: conn, actor: actor, device: device} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/sophos_devices/#{device.sophos_id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["hostname"] == "production-mac"
    assert data["serial_number"] == "P28DA81LMD5T"
    assert data["health_overall"] == "good"
  end

  test "show does not return another account's endpoint", %{conn: conn, actor: actor} do
    other = sophos_device_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/sophos_devices/#{other.sophos_id}")
           |> json_response(404)
  end

  test "is forbidden when the account feature is off", %{conn: conn, actor: actor, account: account} do
    disable_device_posture(account)

    response = conn |> authorize_conn(actor) |> get("/sophos_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/sophos_devices/#{device.sophos_id}") |> json_response(401)
  end
end
