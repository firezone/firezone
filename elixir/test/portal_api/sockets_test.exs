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
end
