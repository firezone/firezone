defmodule PortalAPI.Plugs.RejectUnknownSocketsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias PortalAPI.Plugs.RejectUnknownSockets

  @opts RejectUnknownSockets.init([])

  defp upgrade(conn), do: put_req_header(conn, "upgrade", "websocket")

  describe "call/2" do
    test "passes through requests that are not WebSocket upgrades" do
      conn = conn(:get, "https://api.firezone.dev/clients")

      result = RejectUnknownSockets.call(conn, @opts)

      assert result == conn
      refute result.halted
    end

    test "rejects an upgrade to a socket path that is not mounted" do
      conn = upgrade(conn(:get, "https://api.firezone.dev/client/v4/websocket"))

      result = RejectUnknownSockets.call(conn, @opts)

      assert result.halted
      assert result.status == 400

      assert get_resp_header(result, "content-type") == ["application/problem+json; charset=utf-8"]

      body = JSON.decode!(result.resp_body)
      assert body["code"] == "unknown_socket"
      assert body["detail"] =~ "/client/v4/websocket"
    end

    test "names the mounted socket paths in the response" do
      conn = upgrade(conn(:get, "https://api.firezone.dev/client/v4/websocket"))

      detail = JSON.decode!(RejectUnknownSockets.call(conn, @opts).resp_body)["detail"]

      for {path, _socket, _opts} <- PortalAPI.Endpoint.__sockets__() do
        assert detail =~ path <> "/websocket"
      end
    end

    test "matches the upgrade header case-insensitively" do
      conn =
        conn(:get, "https://api.firezone.dev/client/v4/websocket")
        |> put_req_header("upgrade", "WebSocket")

      assert RejectUnknownSockets.call(conn, @opts).status == 400
    end

    test "logs the requested path and the user agent" do
      conn =
        upgrade(conn(:get, "https://api.firezone.dev/client/v4/websocket"))
        |> put_req_header("user-agent", "iOS/18.0 connlib/1.5.0")

      log = capture_log(fn -> RejectUnknownSockets.call(conn, @opts) end)

      assert log =~ "Rejected WebSocket upgrade to an unmounted path"
      assert log =~ "/client/v4/websocket"
      assert log =~ "iOS/18.0 connlib/1.5.0"
    end
  end
end
