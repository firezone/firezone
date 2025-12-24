defmodule API.RateLimitTest do
  use API.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    }
  end

  describe "verify rate limit" do
    test "allows requests under rate limit", %{conn: conn, account: account, actor: actor} do
      api_request_cost = API.RateLimit.default_cost()
      capacity = div(Domain.Config.fetch_env!(:api, API.RateLimit)[:capacity], api_request_cost)
      _resources = for _ <- 1..3, do: Fixtures.Resources.create_resource(%{account: account})

      for _ <- 0..(capacity - 1) do
        resp_conn = call_api(conn, actor)
        assert %{"data" => _data, "metadata" => _metadata} = json_response(resp_conn, 200)
      end
    end

    test "returns 429 after hitting rate limit", %{conn: conn, account: account, actor: actor} do
      api_request_cost = API.RateLimit.default_cost()
      capacity = div(Domain.Config.fetch_env!(:api, API.RateLimit)[:capacity], api_request_cost)
      _resources = for _ <- 1..3, do: Fixtures.Resources.create_resource(%{account: account})

      for _ <- 0..(capacity - 1) do
        resp_conn = call_api(conn, actor)
        assert %{"data" => _data, "metadata" => _metadata} = json_response(resp_conn, 200)
      end

      resp_conn = call_api(conn, actor)
      assert %{"error" => %{"reason" => "Too Many Requests"}} = json_response(resp_conn, 429)
    end

    test "allows requests after time window", %{conn: conn, account: account, actor: actor} do
      api_request_cost = API.RateLimit.default_cost()
      capacity = div(Domain.Config.fetch_env!(:api, API.RateLimit)[:capacity], api_request_cost)

      _resources = for _ <- 1..3, do: Fixtures.Resources.create_resource(%{account: account})

      for _ <- 0..(capacity - 1) do
        resp_conn = call_api(conn, actor)
        assert %{"data" => _data, "metadata" => _metadata} = json_response(resp_conn, 200)
      end

      resp_conn = call_api(conn, actor)
      assert %{"error" => %{"reason" => "Too Many Requests"}} = json_response(resp_conn, 429)

      :timer.sleep(:timer.seconds(1))

      resp_conn = call_api(conn, actor)
      assert %{"data" => _data, "metadata" => _metadata} = json_response(resp_conn, 200)
    end
  end

  def call_api(conn, actor) do
    conn
    |> authorize_conn(actor)
    |> put_req_header("content-type", "application/json")
    |> get("/resources")
  end
end
