defmodule PortalAPI.Plugs.MCPRateLimitTest do
  use ExUnit.Case, async: true

  alias PortalAPI.Plugs.MCPRateLimit

  test "limits requests independently by source IP before authentication" do
    unique = System.unique_integer([:positive])
    first_ip = {198, 51, rem(unique, 250), 1}
    second_ip = {198, 51, rem(unique, 250), 2}
    opts = MCPRateLimit.init(refill_rate: 0, capacity: 1)

    first = Plug.Test.conn(:post, "/mcp") |> Map.put(:remote_ip, first_ip)
    second = Plug.Test.conn(:post, "/mcp") |> Map.put(:remote_ip, second_ip)

    refute MCPRateLimit.call(first, opts).halted

    denied = MCPRateLimit.call(first, opts)
    assert denied.halted
    assert denied.status == 429
    [retry_after] = Plug.Conn.get_resp_header(denied, "retry-after")
    seconds = String.to_integer(retry_after)
    body = JSON.decode!(denied.resp_body)
    assert body["retry_after_seconds"] == seconds
    assert body["detail"] == "Rate limit exceeded. Retry after #{seconds} seconds."

    refute MCPRateLimit.call(second, opts).halted
  end
end
