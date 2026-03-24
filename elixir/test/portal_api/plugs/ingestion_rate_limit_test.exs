defmodule PortalAPI.Plugs.IngestionRateLimitTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture(limits: %{ingestion_refill_rate: 5, ingestion_capacity: 5})
    site = site_fixture(account: account)
    token = gateway_token_fixture(account: account, site: site)
    encoded = encode_gateway_token(token)

    # Deterministic unique IP to avoid collisions across async tests
    counter = System.unique_integer([:positive, :monotonic])

    unique_ip =
      {10, rem(div(counter, 65_536), 256), rem(div(counter, 256), 256), rem(counter, 254) + 1}

    %{encoded: encoded, unique_ip: unique_ip}
  end

  describe "rate limiting" do
    test "returns 429 with retry-after after exceeding rate limit", %{
      conn: conn,
      encoded: encoded,
      unique_ip: unique_ip
    } do
      flow_record = %{
        "flow_id" => Ecto.UUID.generate(),
        "device_id" => Ecto.UUID.generate(),
        "role" => "initiator",
        "flow_start" => "2026-03-20T10:00:00.000000Z",
        "flow_end" => "2026-03-20T10:05:00.000000Z"
      }

      for _ <- 1..5 do
        build_conn()
        |> Map.put(:remote_ip, unique_ip)
        |> put_req_header("user-agent", "testing")
        |> put_req_header("authorization", "Bearer " <> encoded)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [flow_record]})
      end

      conn =
        conn
        |> Map.put(:remote_ip, unique_ip)
        |> put_req_header("authorization", "Bearer " <> encoded)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [flow_record]})

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end
  end
end
