defmodule PortalAPI.IruPostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.IruFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/iru_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = iru_posture_provider_fixture(account: actor.account)
    second = iru_posture_provider_fixture(account: actor.account)
    iru_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/iru_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "iru"))
  end

  test "never returns the API token", %{conn: conn, actor: actor} do
    provider = iru_posture_provider_fixture(account: actor.account)

    data =
      conn
      |> authorize_conn(actor)
      |> get("/iru_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["subdomain"] == provider.subdomain
    assert data["region"] == "us"
    refute Map.has_key?(data, "api_token")
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = iru_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/iru_posture_providers/#{provider.id}")
           |> json_response(404)
  end
end
