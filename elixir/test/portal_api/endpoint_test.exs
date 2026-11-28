defmodule PortalAPI.EndpointTest do
  use ExUnit.Case, async: true

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

  test "mounts the plain WebSocket client, gateway and relay sockets" do
    sockets = PortalAPI.Endpoint.__sockets__()

    assert {"/client/v5", PortalAPI.Client.V5.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/client/v5" end)

    assert {"/gateway/v4", PortalAPI.Gateway.V4.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/gateway/v4" end)

    assert {"/relay/v2", PortalAPI.Relay.V2.Socket, _opts} =
             Enum.find(sockets, fn {path, _socket, _opts} -> path == "/relay/v2" end)
  end

  test "every Phoenix socket keeps phx_error payloads empty for released devices" do
    for {path, socket, opts} <- PortalAPI.Endpoint.__sockets__(),
        Code.ensure_loaded?(socket) and function_exported?(socket, :__channel__, 1) do
      assert {PortalAPI.Sockets.Serializer, "~> 1.0.0"} in opts[:websocket][:serializer],
             "#{path} does not use PortalAPI.Sockets.Serializer"
    end
  end
end
