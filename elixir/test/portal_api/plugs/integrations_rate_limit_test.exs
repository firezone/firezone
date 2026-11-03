defmodule PortalAPI.Plugs.IntegrationsRateLimitTest do
  use PortalAPI.ConnCase, async: true

  alias PortalAPI.Plugs.IntegrationsRateLimit

  setup do
    counter = System.unique_integer([:positive, :monotonic])

    %{
      unique_ip:
        {10, rem(div(counter, 65_536), 256), rem(div(counter, 256), 256), rem(counter, 254) + 1}
    }
  end

  test "allows up to capacity then returns 429 with retry-after", %{unique_ip: unique_ip} do
    opts = IntegrationsRateLimit.init(refill_rate: 1, capacity: 3)

    for _ <- 1..3 do
      conn = build_conn() |> Map.put(:remote_ip, unique_ip) |> IntegrationsRateLimit.call(opts)
      refute conn.halted
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = build_conn() |> Map.put(:remote_ip, unique_ip) |> IntegrationsRateLimit.call(opts)

        assert conn.status == 429
        assert conn.halted
        assert [retry_after] = get_resp_header(conn, "retry-after")
        assert String.to_integer(retry_after) > 0
      end)

    assert log =~ "Webhook rate limit exceeded"
  end

  test "different IPs have independent buckets", %{unique_ip: unique_ip} do
    opts = IntegrationsRateLimit.init(refill_rate: 1, capacity: 1)

    conn = build_conn() |> Map.put(:remote_ip, unique_ip) |> IntegrationsRateLimit.call(opts)
    refute conn.halted

    conn =
      build_conn()
      |> Map.put(:remote_ip, put_elem(unique_ip, 0, 11))
      |> IntegrationsRateLimit.call(opts)

    refute conn.halted
  end
end
