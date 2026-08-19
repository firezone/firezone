defmodule PortalAPI.IruDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.IruFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = iru_posture_provider_fixture(account: account)

    device =
      iru_device_fixture(
        provider: provider,
        device_name: "Managed MacBook",
        platform: "Mac",
        filevault_enabled: true
      )

    %{account: account, actor: actor, provider: provider, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = iru_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/iru_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"iru_id" => id}] = response["data"]
    assert id == device.iru_id
    refute id == other.iru_id
  end

  test "show returns the device fields", %{conn: conn, actor: actor, device: device} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/iru_devices/#{device.iru_id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["device_name"] == "Managed MacBook"
    assert data["platform"] == "Mac"
    assert data["filevault_enabled"] == true
  end

  test "is forbidden when the global flag is off", %{conn: conn, actor: actor} do
    enable_device_posture(false)

    response = conn |> authorize_conn(actor) |> get("/iru_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/iru_devices/#{device.iru_id}") |> json_response(401)
  end
end
