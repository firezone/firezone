defmodule PortalAPI.IntuneIntegrationControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.IntuneFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    integration = intune_integration_fixture(account: account)
    %{account: account, actor: actor, integration: integration}
  end

  test "index requires authorization", %{conn: conn} do
    assert conn |> get("/intune_integrations") |> json_response(401)
  end

  test "index returns only the authorized account's integration", %{
    conn: conn,
    actor: actor,
    integration: integration
  } do
    other = intune_integration_fixture()

    response =
      conn
      |> authorize_conn(actor)
      |> get("/intune_integrations")
      |> json_response(200)

    assert Enum.any?(response["data"], &(&1["id"] == integration.id))
    refute Enum.any?(response["data"], &(&1["id"] == other.id))
  end

  test "show returns integration sync state", %{conn: conn, actor: actor, integration: integration} do
    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_integrations/#{integration.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == integration.id
    assert data["tenant_id"] == integration.tenant_id
    assert data["type"] == "intune"
    assert data["is_verified"]
  end

  test "show does not expose another account", %{conn: conn, actor: actor} do
    other = intune_integration_fixture()

    conn = conn |> authorize_conn(actor) |> get("/intune_integrations/#{other.id}")
    assert json_response(conn, 404)
  end
end
