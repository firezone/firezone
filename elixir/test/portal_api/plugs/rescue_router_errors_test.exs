defmodule PortalAPI.Plugs.RescueRouterErrorsTest do
  use PortalAPI.ConnCase, async: true

  test "renders an unknown route as problem details", %{conn: conn} do
    conn = get(conn, "/nope")

    assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
             json_response(conn, 404)

    assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
  end

  test "unknown routes and unmounted sockets return 404 instead of redirecting", %{conn: conn} do
    Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

    for path <- ["/nope", "/client/v1/websocket", "/client/v4/websocket", "/gateway/v3/websocket"] do
      response = get(%{conn | host: "api.firezone.dev"}, path)
      assert json_response(response, 404)["status"] == 404
      assert get_resp_header(response, "location") == []
    end
  end

  test "matched REST routes redirect before authentication", %{conn: conn} do
    Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

    response = get(%{conn | host: "api.firezone.dev"}, "/clients?limit=5")

    assert response.status == 308
    assert get_resp_header(response, "location") == ["https://rest-api.firezone.dev/clients?limit=5"]
  end

  test "mounted sockets stay on the API host", %{conn: conn} do
    Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

    for {path, _socket, _opts} <- PortalAPI.Endpoint.__sockets__() do
      response = get(%{conn | host: "api.firezone.dev"}, path <> "/websocket")

      assert response.status == 401
      assert get_resp_header(response, "location") == []
    end
  end

  test "flow API requests reach authentication without redirecting", %{conn: conn} do
    Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")
    Portal.Config.put_env_override(:flow_logs_api_url, "https://flow-api.firezone.dev/")

    for {method, path} <- [{:get, "/clients"}, {:post, "/ingestion/flow_logs"}] do
      response = dispatch(%{conn | host: "flow-api.firezone.dev"}, @endpoint, method, path)

      assert response.status == 401
      assert get_resp_header(response, "location") == []
    end
  end
end
