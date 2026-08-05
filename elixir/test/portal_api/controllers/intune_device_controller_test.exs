defmodule PortalAPI.IntuneDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.IntuneFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    integration = intune_integration_fixture(account: account)
    client = client_fixture(account: account)

    device =
      intune_device_fixture(
        integration: integration,
        device_id: client.id,
        device_name: "Managed Surface",
        compliance_state: "compliant",
        attributes: %{"providerField" => "retained"}
      )

    %{account: account, actor: actor, integration: integration, client: client, device: device}
  end

  test "index is paginated and account scoped", %{conn: conn, actor: actor, device: device} do
    other = intune_device_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/intune_devices", limit: 1)
      |> json_response(200)

    assert response["metadata"]["count"] == 1
    assert [%{"id" => id}] = response["data"]
    assert id == device.id
    refute id == other.id
  end

  test "show returns provider fields and the optional Firezone device link", %{
    conn: conn,
    actor: actor,
    client: client,
    device: device
  } do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_devices/#{device.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["device_id"] == client.id
    assert data["device_name"] == "Managed Surface"
    assert data["compliance_state"] == "compliant"
    assert data["attributes"] == %{"providerField" => "retained"}
  end

  test "show requires authorization", %{conn: conn, device: device} do
    assert conn |> get("/intune_devices/#{device.id}") |> json_response(401)
  end
end
