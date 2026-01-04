defmodule PortalAPI.SocketsTest do
  use ExUnit.Case, async: true
  alias PortalAPI.Sockets

  describe "extract_token/2" do
    test "returns token from x-authorization header with Bearer prefix" do
      params = %{}
      connect_info = %{x_headers: [{"x-authorization", "Bearer my-token-123"}]}

      assert Sockets.extract_token(params, connect_info) == {:ok, "my-token-123"}
    end

    test "returns token from params when header is missing" do
      params = %{"token" => "param-token-456"}
      connect_info = %{x_headers: []}

      assert Sockets.extract_token(params, connect_info) == {:ok, "param-token-456"}
    end

    test "returns token from params when x_headers key is missing" do
      params = %{"token" => "param-token-789"}
      connect_info = %{}

      assert Sockets.extract_token(params, connect_info) == {:ok, "param-token-789"}
    end

    test "header takes precedence over params" do
      params = %{"token" => "param-token"}
      connect_info = %{x_headers: [{"x-authorization", "Bearer header-token"}]}

      assert Sockets.extract_token(params, connect_info) == {:ok, "header-token"}
    end

    test "returns error when neither header nor param is present" do
      params = %{}
      connect_info = %{x_headers: []}

      assert Sockets.extract_token(params, connect_info) == :error
    end

    test "returns error when header exists but without Bearer prefix" do
      params = %{}
      connect_info = %{x_headers: [{"x-authorization", "my-token"}]}

      assert Sockets.extract_token(params, connect_info) == :error
    end

    test "returns error when header exists with wrong prefix" do
      params = %{}
      connect_info = %{x_headers: [{"x-authorization", "Basic my-token"}]}

      assert Sockets.extract_token(params, connect_info) == :error
    end

    test "handles multiple x_headers correctly" do
      params = %{}

      connect_info = %{
        x_headers: [
          {"x-forwarded-for", "192.168.1.1"},
          {"x-authorization", "Bearer correct-token"},
          {"x-custom", "value"}
        ]
      }

      assert Sockets.extract_token(params, connect_info) == {:ok, "correct-token"}
    end

    test "falls back to params when header value is empty" do
      params = %{"token" => "fallback-token"}
      connect_info = %{x_headers: [{"x-authorization", ""}]}

      assert Sockets.extract_token(params, connect_info) == {:ok, "fallback-token"}
    end
  end

  describe "handle_error/2" do
    test "returns 401 for invalid_token" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :invalid_token)

      assert result.status == 401
      assert result.resp_body == "Invalid token"
    end

    test "returns 401 for missing_token" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :missing_token)

      assert result.status == 401
      assert result.resp_body == "Missing token"
    end

    test "returns 403 for account_disabled" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :account_disabled)

      assert result.status == 403
      assert result.resp_body == "The account is disabled"
    end

    test "returns 403 for unauthenticated" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :unauthenticated)

      assert result.status == 403
      assert result.resp_body == "Forbidden"
    end

    test "returns 503 with retry-after header for rate_limit" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :rate_limit)

      assert result.status == 503
      assert result.resp_body == "Service Unavailable"
      assert Plug.Conn.get_resp_header(result, "retry-after") == ["1"]
    end
  end
end
