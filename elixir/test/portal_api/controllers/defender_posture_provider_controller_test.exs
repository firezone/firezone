defmodule PortalAPI.DefenderPostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.DefenderFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/defender_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = defender_posture_provider_fixture(account: actor.account)
    second = defender_posture_provider_fixture(account: actor.account)
    defender_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/defender_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "defender"))
  end

  test "returns the provider with the name from the shared row", %{conn: conn, actor: actor} do
    provider = defender_posture_provider_fixture(account: actor.account, name: "Contoso EDR")

    data =
      conn
      |> authorize_conn(actor)
      |> get("/defender_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["name"] == "Contoso EDR"
    assert data["tenant_id"] == provider.tenant_id
    refute Map.has_key?(data, "error_email_count")
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = defender_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/defender_posture_providers/#{provider.id}")
           |> json_response(404)
  end
end
