defmodule PortalAPI.SantaPostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.SantaFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/santa_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = santa_posture_provider_fixture(account: actor.account)
    second = santa_posture_provider_fixture(account: actor.account)
    santa_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/santa_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "santa"))
  end

  test "returns the tenant URL but never the API key", %{conn: conn, actor: actor} do
    provider = santa_posture_provider_fixture(account: actor.account)

    data =
      conn
      |> authorize_conn(actor)
      |> get("/santa_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["api_url"] == provider.api_url
    refute Map.has_key?(data, "api_key")
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = santa_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/santa_posture_providers/#{provider.id}")
           |> json_response(404)
  end
end
