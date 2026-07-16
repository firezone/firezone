defmodule PortalAPI.EndpointTest do
  use ExUnit.Case, async: true

  test "mounts legacy and v2 client and gateway sockets" do
    sockets = PortalAPI.Endpoint.__sockets__()

    assert {"/client", PortalAPI.Client.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/client" end)

    assert {"/client/v2", PortalAPI.Client.V2.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/client/v2" end)

    assert {"/gateway", PortalAPI.Gateway.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/gateway" end)

    assert {"/gateway/v2", PortalAPI.Gateway.V2.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/gateway/v2" end)
  end
end
