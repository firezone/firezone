defmodule PortalAPI.SentinelOnePostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.SentinelOneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/sentinelone_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = sentinelone_posture_provider_fixture(account: actor.account)
    second = sentinelone_posture_provider_fixture(account: actor.account)
    sentinelone_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/sentinelone_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "sentinelone"))
  end

  test "returns public fields and redacts the API token", %{conn: conn, actor: actor} do
    provider =
      sentinelone_posture_provider_fixture(
        account: actor.account,
        name: "Production S1",
        api_token: "do-not-return"
      )

    data =
      conn
      |> authorize_conn(actor)
      |> get("/sentinelone_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["name"] == "Production S1"
    assert data["management_url"] == provider.management_url
    refute Map.has_key?(data, "api_token")
    refute Map.has_key?(data, "error_email_count")
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = sentinelone_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/sentinelone_posture_providers/#{provider.id}")
           |> json_response(404)
  end
end
