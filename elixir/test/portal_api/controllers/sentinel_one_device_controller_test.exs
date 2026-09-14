defmodule PortalAPI.SentinelOneDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.SentinelOneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    provider = sentinelone_posture_provider_fixture(account: account)

    device =
      sentinelone_device_fixture(
        provider: provider,
        computer_name: "production-mac",
        os_name: "macOS 15.6",
        is_active: true
      )

    %{account: account, actor: actor, provider: provider, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = sentinelone_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/sentinelone_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"uuid" => uuid}] = response["data"]
    assert uuid == device.uuid
    refute uuid == other.uuid
  end

  test "show returns inventory but redacts the endpoint license key", %{
    conn: conn,
    actor: actor,
    device: device
  } do
    device
    |> Ecto.Changeset.change(license_key: "credential-like-inventory")
    |> Portal.Repo.update!()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/sentinelone_devices/#{device.uuid}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["computer_name"] == "production-mac"
    assert data["os_name"] == "macOS 15.6"
    assert data["is_active"]
    refute Map.has_key?(data, "license_key")
  end

  test "is forbidden when the global flag is off", %{conn: conn, actor: actor} do
    enable_device_posture(false)

    response = conn |> authorize_conn(actor) |> get("/sentinelone_devices") |> json_response(403)
    assert response["detail"] == "This feature is not enabled for your account."
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/sentinelone_devices/#{device.uuid}") |> json_response(401)
  end
end
