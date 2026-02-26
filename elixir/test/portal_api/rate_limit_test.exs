defmodule PortalAPI.RateLimitTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ResourceFixtures

  # Use a capacity equal to exactly one request cost and a very slow refill rate
  # so the second request is deterministically denied without any timing sensitivity.
  @rate_limit_capacity PortalAPI.RateLimit.default_cost()
  @rate_limit_refill_rate 1

  setup do
    account =
      account_fixture(
        limits: %{
          monthly_active_users_count: 100,
          api_capacity: @rate_limit_capacity,
          api_refill_rate: @rate_limit_refill_rate
        }
      )

    actor = actor_fixture(type: :api_client, account: account)
    _resources = for _ <- 1..3, do: resource_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "REST API rate limit" do
    test "allows a request when bucket has tokens", %{conn: conn, actor: actor} do
      resp_conn = call_api(conn, actor)
      assert %{"data" => _data, "metadata" => _metadata} = json_response(resp_conn, 200)
    end

    test "returns 429 with retry-after header once bucket is exhausted", %{
      conn: conn,
      actor: actor
    } do
      # First request exhausts the single-request-capacity bucket
      resp_conn = call_api(conn, actor)
      assert json_response(resp_conn, 200)

      # Second request immediately after finds no tokens available
      resp_conn = call_api(conn, actor)
      assert %{"error" => %{"reason" => "Too Many Requests"}} = json_response(resp_conn, 429)

      [retry_after] = get_resp_header(resp_conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end
  end

  defp call_api(conn, actor) do
    conn
    |> authorize_conn(actor)
    |> put_req_header("content-type", "application/json")
    |> get("/resources")
  end
end
