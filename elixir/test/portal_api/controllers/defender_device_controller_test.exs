defmodule PortalAPI.DefenderDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.DefenderFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = defender_posture_provider_fixture(account: account)

    device =
      defender_device_fixture(
        provider: provider,
        computer_dns_name: "onboarded.contoso.com",
        health_status: "Active",
        risk_score: "Medium"
      )

    %{account: account, actor: actor, provider: provider, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = defender_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/defender_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"defender_id" => id}] = response["data"]
    assert id == device.defender_id
    refute id == other.defender_id
  end

  test "show returns the device fields", %{conn: conn, actor: actor, device: device} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/defender_devices/#{device.defender_id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["computer_dns_name"] == "onboarded.contoso.com"
    assert data["health_status"] == "Active"
    assert data["risk_score"] == "Medium"
  end

  test "is forbidden when the global flag is off", %{conn: conn, actor: actor} do
    enable_device_posture(false)

    response = conn |> authorize_conn(actor) |> get("/defender_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/defender_devices/#{device.defender_id}") |> json_response(401)
  end
end
