defmodule PortalAPI.SophosPostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.SophosFixtures

  setup do
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/sophos_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = sophos_posture_provider_fixture(account: actor.account)
    second = sophos_posture_provider_fixture(account: actor.account)
    sophos_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/sophos_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "sophos"))
  end

  test "returns public fields and redacts the client secret", %{conn: conn, actor: actor} do
    provider =
      sophos_posture_provider_fixture(
        account: actor.account,
        name: "Production Sophos",
        client_secret: "do-not-return"
      )

    data =
      conn
      |> authorize_conn(actor)
      |> get("/sophos_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["name"] == "Production Sophos"
    assert data["client_id"] == provider.client_id
    assert data["tenant_id"] == provider.tenant_id
    assert data["data_region_url"] == "https://api-us03.central.sophos.com"
    refute Map.has_key?(data, "client_secret")
    refute Map.has_key?(data, "error_email_count")
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = sophos_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/sophos_posture_providers/#{provider.id}")
           |> json_response(404)
  end
end
