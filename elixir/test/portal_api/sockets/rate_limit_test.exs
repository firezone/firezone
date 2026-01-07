defmodule PortalAPI.Sockets.RateLimitTest do
  use ExUnit.Case, async: true
  alias PortalAPI.Sockets.RateLimit

  describe "check/1" do
    test "allows first request" do
      connect_info = unique_connect_info()
      assert RateLimit.check(connect_info) == :ok
    end

    test "rate limits second request with same IP and token" do
      connect_info = unique_connect_info()

      assert RateLimit.check(connect_info) == :ok
      assert RateLimit.check(connect_info) == {:error, :rate_limit}
    end

    test "allows requests from different IPs with same token" do
      token = unique_token()

      connect_info_1 = build_connect_info(unique_ip(), token)
      connect_info_2 = build_connect_info(unique_ip(), token)

      assert RateLimit.check(connect_info_1) == :ok
      assert RateLimit.check(connect_info_2) == :ok
    end

    test "allows requests from same IP with different tokens" do
      ip = unique_ip()

      connect_info_1 = build_connect_info(ip, "Bearer token_1")
      connect_info_2 = build_connect_info(ip, "Bearer token_2")

      assert RateLimit.check(connect_info_1) == :ok
      assert RateLimit.check(connect_info_2) == :ok
    end

    test "uses x-forwarded-for header when present" do
      token = unique_token()
      real_ip = unique_ip()
      proxy_ip = unique_ip()

      connect_info_1 = %{
        peer_data: %{address: proxy_ip},
        x_headers: [
          {"x-forwarded-for", :inet.ntoa(real_ip) |> to_string()},
          {"x-authorization", token}
        ]
      }

      # Same real IP should be rate limited
      connect_info_2 = %{
        peer_data: %{address: proxy_ip},
        x_headers: [
          {"x-forwarded-for", :inet.ntoa(real_ip) |> to_string()},
          {"x-authorization", token}
        ]
      }

      assert RateLimit.check(connect_info_1) == :ok
      assert RateLimit.check(connect_info_2) == {:error, :rate_limit}
    end

    test "handles missing x-authorization header" do
      connect_info = %{
        peer_data: %{address: unique_ip()},
        x_headers: []
      }

      assert RateLimit.check(connect_info) == :ok
    end

    test "handles missing x_headers" do
      connect_info = %{
        peer_data: %{address: unique_ip()}
      }

      assert RateLimit.check(connect_info) == :ok
    end

    test "treats requests without token as separate bucket" do
      ip = unique_ip()

      # Request without token
      connect_info_no_token = %{
        peer_data: %{address: ip},
        x_headers: []
      }

      # Request with token
      connect_info_with_token = %{
        peer_data: %{address: ip},
        x_headers: [{"x-authorization", "Bearer some_token"}]
      }

      assert RateLimit.check(connect_info_no_token) == :ok
      assert RateLimit.check(connect_info_with_token) == :ok
    end
  end

  describe "retry_after_seconds/0" do
    test "returns retry-after value" do
      assert RateLimit.retry_after_seconds() == 1
    end
  end

  # Helper functions to generate unique test data
  defp unique_connect_info do
    ip = unique_ip()
    token = unique_token()
    build_connect_info(ip, token)
  end

  defp build_connect_info(ip, token) do
    %{
      peer_data: %{address: ip},
      x_headers: [{"x-authorization", token}]
    }
  end

  defp unique_ip do
    # Generate a random IP to avoid test interference
    {:rand.uniform(255), :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end

  defp unique_token do
    "Bearer " <> (:crypto.strong_rand_bytes(16) |> Base.encode64())
  end
end
