defmodule Portal.Intune.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.IntuneFixtures

  alias Portal.Intune.{APIClient, Device, Sync}

  setup do
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "not mocked"}) end)
    :ok
  end

  test "syncs managed devices and links by attested MDM device ID before serial number" do
    account = account_fixture()
    integration = intune_integration_fixture(account: account)

    mdm_client =
      client_fixture(
        account: account,
        last_attested_mdm_device_id: "managed-device-1",
        last_attested_device_serial: "WRONG-SERIAL"
      )

    serial_client =
      client_fixture(
        account: account,
        last_attested_mdm_device_id: "different-managed-device",
        last_attested_device_serial: "serial-two"
      )

    Req.Test.expect(APIClient, 2, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
          Req.Test.json(conn, %{"access_token" => "graph-token"})

        conn.request_path == "/v1.0/deviceManagement/managedDevices" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer graph-token"]

          Req.Test.json(conn, %{
            "value" => [
              managed_device(%{
                "id" => "managed-device-1",
                "serialNumber" => "serial-one",
                "deviceName" => "Alice's Surface"
              }),
              managed_device(%{
                "id" => "managed-device-2",
                "serialNumber" => "SERIAL-TWO",
                "deviceName" => "Bob's Mac"
              })
            ]
          })
      end
    end)

    assert :ok = perform_job(Sync, %{"device_integration_id" => integration.id})

    devices =
      from(d in Device, order_by: d.intune_id)
      |> Repo.all()

    assert [first, second] = devices
    assert first.device_id == mdm_client.id
    assert first.device_name == "Alice's Surface"
    assert first.compliance_state == "compliant"
    assert first.attributes["operatingSystem"] == "Windows"
    assert second.device_id == serial_client.id

    integration = Repo.reload!(integration)
    assert integration.synced_at
    refute integration.errored_at
  end

  test "keeps an unlinked inventory row and nilifies its Firezone link on device deletion" do
    account = account_fixture()
    integration = intune_integration_fixture(account: account)
    client = client_fixture(account: account)

    linked =
      intune_device_fixture(
        integration: integration,
        device_id: client.id,
        intune_id: "linked-device"
      )

    unlinked =
      intune_device_fixture(
        integration: integration,
        intune_id: "inventory-only-device",
        device_name: "Inventory Only"
      )

    linked_projection = Repo.get!(Portal.DeviceInventory, client.id)
    assert linked_projection.intune_device_id == linked.id
    assert linked_projection.ipv4 == client.ipv4
    assert linked_projection.ipv6 == client.ipv6
    assert linked_projection.connected

    unlinked_projection = Repo.get!(Portal.DeviceInventory, unlinked.id)
    refute unlinked_projection.connected
    assert is_nil(unlinked_projection.ipv4)
    assert unlinked_projection.name == "Inventory Only"

    Repo.delete!(client)

    linked = Repo.reload!(linked)
    assert is_nil(linked.device_id)
    refute Repo.get!(Portal.DeviceInventory, linked.id).connected
  end

  test "deletes Intune devices absent from a completed sync" do
    integration = intune_integration_fixture()
    stale = intune_device_fixture(integration: integration, intune_id: "stale-device")

    Req.Test.expect(APIClient, 2, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "graph-token"})
      else
        Req.Test.json(conn, %{"value" => [managed_device(%{"id" => "current-device"})]})
      end
    end)

    assert :ok = perform_job(Sync, %{device_integration_id: integration.id})
    refute Repo.get(Device, stale.id)
    assert Repo.get_by!(Device, intune_id: "current-device")
  end

  test "updates an existing managed device by its primary key on subsequent syncs" do
    integration = intune_integration_fixture()

    Req.Test.expect(APIClient, 4, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "graph-token"})
      else
        Req.Test.json(conn, %{"value" => [managed_device(%{"id" => "managed-device"})]})
      end
    end)

    assert :ok = perform_job(Sync, %{device_integration_id: integration.id})
    first = Repo.get_by!(Device, intune_id: "managed-device")

    assert :ok = perform_job(Sync, %{device_integration_id: integration.id})
    assert Repo.aggregate(Device, :count) == 1
    assert Repo.get_by!(Device, intune_id: "managed-device").id == first.id
  end

  defp managed_device(overrides) do
    Map.merge(
      %{
        "id" => "managed-device",
        "deviceName" => "Managed Device",
        "managedDeviceName" => "managed-device",
        "serialNumber" => "SERIAL",
        "azureADDeviceId" => Ecto.UUID.generate(),
        "userPrincipalName" => "owner@example.com",
        "userDisplayName" => "Device Owner",
        "operatingSystem" => "Windows",
        "osVersion" => "11.0",
        "model" => "Surface Laptop",
        "manufacturer" => "Microsoft",
        "complianceState" => "compliant",
        "managementAgent" => "mdm",
        "isEncrypted" => true,
        "enrolledDateTime" => "2026-08-01T01:02:03Z",
        "lastSyncDateTime" => "2026-08-02T01:02:03Z"
      },
      overrides
    )
  end
end
