defmodule PortalAPI.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "mounts legacy, v2 and v3 client sockets and legacy and v2 gateway sockets" do
    sockets = PortalAPI.Endpoint.__sockets__()

    assert {"/client", PortalAPI.Client.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/client" end)

    assert {"/client/v2", PortalAPI.Client.V2.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/client/v2" end)

    assert {"/client/v3", PortalAPI.Client.V3.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/client/v3" end)

    assert {"/gateway", PortalAPI.Gateway.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/gateway" end)

    assert {"/gateway/v2", PortalAPI.Gateway.V2.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/gateway/v2" end)
  end

  test "rejects a WebSocket upgrade to an unmounted socket instead of redirecting it" do
    Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

    conn =
      conn(:get, "https://api.firezone.dev/client/v4/websocket")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> PortalAPI.Endpoint.call([])

    assert conn.status == 400
    assert Plug.Conn.get_resp_header(conn, "location") == []
  end
end
