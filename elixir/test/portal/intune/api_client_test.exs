defmodule Portal.Intune.APIClientTest do
  use ExUnit.Case, async: true

  alias Portal.Intune.APIClient

  setup do
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "not mocked"}) end)
    :ok
  end

  test "uses a client secret for development credentials" do
    test_pid = self()

    Req.Test.expect(APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_body, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "graph-token"})
    end)

    assert {:ok, %Req.Response{status: 200}} = APIClient.get_access_token("tenant-id")

    assert_receive {:token_body, body}
    assert body["client_id"] == "test_intune_client_id"
    assert body["client_secret"] == "test_intune_client_secret"
    assert body["scope"] == "https://graph.microsoft.com/.default"
  end

  test "uses a workload identity federation assertion when no secret is configured" do
    test_pid = self()
    Portal.Config.put_env_override(:portal, APIClient, client_secret: nil)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "workload-identity-assertion",
        "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
      })
    end)

    Req.Test.expect(APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_body, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "graph-token"})
    end)

    assert {:ok, %Req.Response{status: 200}} = APIClient.get_access_token("tenant-id")

    assert_receive {:token_body, body}
    assert body["client_assertion"] == "workload-identity-assertion"

    assert body["client_assertion_type"] ==
             "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

    refute body["client_secret"]
  end

  test "streams every managed-device page" do
    Req.Test.expect(APIClient, 2, fn conn ->
      case conn.query_string do
        "$skiptoken=next" ->
          Req.Test.json(conn, %{"value" => [%{"id" => "device-2"}]})

        _ ->
          Req.Test.json(conn, %{
            "value" => [%{"id" => "device-1"}],
            "@odata.nextLink" =>
              "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=next"
          })
      end
    end)

    assert APIClient.stream_managed_devices("token") |> Enum.to_list() == [
             [%{"id" => "device-1"}],
             [%{"id" => "device-2"}]
           ]
  end
end
