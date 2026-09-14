defmodule PortalAPI.SantaDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.SantaFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = santa_posture_provider_fixture(account: account)
    device = santa_device_fixture(provider: provider, hostname: "managed-mac", sip_status: 1)

    %{actor: actor, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = santa_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/santa_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"santa_id" => id}] = response["data"]
    assert id == device.santa_id
    refute id == other.santa_id
  end

  test "show returns Santa posture fields", %{conn: conn, actor: actor, device: device} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/santa_devices/#{device.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["hostname"] == "managed-mac"
    assert data["sip_status"] == 1
    assert data["last_seen_client_mode"] == "LOCKDOWN"
  end

  test "is forbidden when device posture is off", %{conn: conn, actor: actor} do
    enable_device_posture(false)
    assert conn |> authorize_conn(actor) |> get("/santa_devices") |> json_response(403)
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/santa_devices/#{device.id}") |> json_response(401)
  end
end
