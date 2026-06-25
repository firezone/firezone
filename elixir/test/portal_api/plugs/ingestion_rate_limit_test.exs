defmodule PortalAPI.Plugs.IngestionRateLimitTest do
  use PortalAPI.ConnCase, async: true

  alias PortalAPI.Plugs.IngestionRateLimit

  setup do
    # Deterministic unique IP to avoid bucket collisions across async tests.
    counter = System.unique_integer([:positive, :monotonic])

    unique_ip =
      {10, rem(div(counter, 65_536), 256), rem(div(counter, 256), 256), rem(counter, 254) + 1}

    %{unique_ip: unique_ip}
  end

  describe "rate limiting" do
    test "allows up to capacity then returns 429 with retry-after", %{unique_ip: unique_ip} do
      opts = IngestionRateLimit.init(refill_rate: 0, capacity: 5)

      for _ <- 1..5 do
        conn = build_conn() |> Map.put(:remote_ip, unique_ip) |> IngestionRateLimit.call(opts)
        refute conn.halted
      end

      conn = build_conn() |> Map.put(:remote_ip, unique_ip) |> IngestionRateLimit.call(opts)

      assert conn.status == 429
      assert conn.halted
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "different IPs have independent buckets", %{unique_ip: unique_ip} do
      opts = IngestionRateLimit.init(refill_rate: 0, capacity: 1)
      other_ip = put_elem(unique_ip, 0, 11)

      conn = build_conn() |> Map.put(:remote_ip, unique_ip) |> IngestionRateLimit.call(opts)
      refute conn.halted

      conn = build_conn() |> Map.put(:remote_ip, other_ip) |> IngestionRateLimit.call(opts)
      refute conn.halted
    end
  end
end
