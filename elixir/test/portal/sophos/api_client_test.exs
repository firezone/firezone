defmodule Portal.Sophos.APIClientTest do
  use ExUnit.Case, async: true

  alias Portal.Sophos.APIClient

  test "verify returns the tenant and regional host whoami names" do
    stub(fn
      %{request_path: "/whoami/v1"} = conn ->
        Req.Test.json(conn, %{
          "id" => "57ca9a6b-885f-4e36-95ec-290548c26059",
          "idType" => "tenant",
          "apiHosts" => %{
            "global" => "https://api.central.sophos.com",
            "dataRegion" => "https://api-eu01.central.sophos.com/"
          }
        })

      %{host: "api-eu01.central.sophos.com", request_path: "/endpoint/v1/endpoints"} = conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["pageSize"] == "1"
        assert Plug.Conn.get_req_header(conn, "x-tenant-id") == ["57ca9a6b-885f-4e36-95ec-290548c26059"]
        Req.Test.json(conn, %{"items" => [], "pages" => %{"size" => 1}})
    end)

    assert APIClient.verify("client", "secret") ==
             {:ok,
              %{
                tenant_id: "57ca9a6b-885f-4e36-95ec-290548c26059",
                data_region_url: "https://api-eu01.central.sophos.com"
              }}
  end

  test "verify rejects partner credentials" do
    stub(fn %{request_path: "/whoami/v1"} = conn ->
      Req.Test.json(conn, %{
        "id" => "57ca9a6b-885f-4e36-95ec-290548c26059",
        "idType" => "partner",
        "apiHosts" => %{"global" => "https://api.central.sophos.com"}
      })
    end)

    assert APIClient.verify("client", "secret") == {:error, :unsupported_credentials}
  end

  test "verify never sends the token to a host that is not Sophos" do
    stub(fn %{request_path: "/whoami/v1"} = conn ->
      Req.Test.json(conn, %{
        "id" => "57ca9a6b-885f-4e36-95ec-290548c26059",
        "idType" => "tenant",
        "apiHosts" => %{"dataRegion" => "https://attacker.example.com"}
      })
    end)

    assert {:error, {:invalid_response, _message, "https://attacker.example.com"}} =
             APIClient.verify("client", "secret")
  end

  test "verify returns the token error" do
    Req.Test.stub(APIClient, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalidClient"})
    end)

    assert {:error, %Req.Response{status: 401}} = APIClient.verify("client", "wrong")
  end

  defp stub(routes) do
    Req.Test.stub(APIClient, fn
      %{request_path: "/api/v2/oauth2/token"} = conn -> Req.Test.json(conn, %{"access_token" => "jwt"})
      conn -> routes.(conn)
    end)
  end
end
