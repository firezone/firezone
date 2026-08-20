defmodule PortalAPI.IntunePostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/intune_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = intune_posture_provider_fixture(account: actor.account)
    second = intune_posture_provider_fixture(account: actor.account)
    intune_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "intune"))
  end

  test "returns a provider and its sync state", %{conn: conn, actor: actor} do
    provider = intune_posture_provider_fixture(account: actor.account)

    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["tenant_id"] == provider.tenant_id
    assert data["type"] == "intune"
    assert data["is_verified"]
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = intune_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/intune_posture_providers/#{provider.id}")
           |> json_response(404)
  end
end
