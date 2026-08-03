defmodule PortalWeb.DeviceInventoryTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.IntuneFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    integration = intune_integration_fixture(account: account)
    %{account: account, actor: actor, integration: integration}
  end

  test "shows an Intune inventory device before it connects", %{
    conn: conn,
    account: account,
    actor: actor,
    integration: integration
  } do
    device =
      intune_device_fixture(
        integration: integration,
        device_name: "Pre-enrolled Surface",
        user_display_name: "Alice Example",
        user_principal_name: "alice@example.com",
        compliance_state: "compliant",
        serial_number: "PRE-123"
      )

    {:ok, lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/devices")

    assert html =~ "Devices"
    assert html =~ "Pre-enrolled Surface"
    assert html =~ "Alice Example"
    assert html =~ "Intune"
    assert html =~ "Not connected"
    assert html =~ "Allocated on connect"

    lv |> element("#client-#{device.id}") |> render_click()
    assert_patch(lv, ~p"/#{account}/devices/#{device.id}")

    panel = render(lv)
    assert panel =~ "Microsoft Intune"
    assert panel =~ "PRE-123"
    assert panel =~ "This device has not connected to Firezone yet"
  end

  test "coalesces a linked Intune record with its Firezone connection and tunnel addresses", %{
    conn: conn,
    account: account,
    actor: actor,
    integration: integration
  } do
    client = client_fixture(account: account, actor: actor, name: "Connected Laptop")

    intune_device_fixture(
      integration: integration,
      device_id: client.id,
      device_name: "Managed Connected Laptop",
      serial_number: "LINKED-123",
      manufacturer: "Microsoft",
      model: "Surface Laptop",
      compliance_state: "noncompliant"
    )

    {:ok, lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/devices")

    assert html =~ "Managed Connected Laptop"
    assert html =~ to_string(client.ipv4)
    assert html =~ to_string(client.ipv6)
    assert html =~ "Intune"
    assert html =~ "Firezone"
    assert html =~ "Noncompliant"
    assert length(Floki.find(Floki.parse_document!(html), "#client-#{client.id}")) == 1

    lv |> element("#client-#{client.id}") |> render_click()
    panel = render(lv)
    assert panel =~ "LINKED-123"
    assert panel =~ "Surface Laptop"
    assert panel =~ "Tunnel IPv4"
    assert panel =~ to_string(client.ipv4)
  end
end
