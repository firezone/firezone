defmodule PortalAPI.IntuneIntegrationControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.IntuneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/intune_integration") |> json_response(401)
  end

  test "returns the account's integration and its sync state", %{conn: conn, actor: actor} do
    integration = intune_integration_fixture(account: actor.account)

    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_integration")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == integration.id
    assert data["tenant_id"] == integration.tenant_id
    assert data["type"] == "intune"
    assert data["is_verified"]
  end

  test "does not return another account's integration", %{conn: conn, actor: actor} do
    intune_integration_fixture()

    assert conn |> authorize_conn(actor) |> get("/intune_integration") |> json_response(404)
  end

  test "returns not found when no integration is configured", %{conn: conn, actor: actor} do
    assert conn |> authorize_conn(actor) |> get("/intune_integration") |> json_response(404)
  end
end
