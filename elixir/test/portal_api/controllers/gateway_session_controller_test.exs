defmodule PortalAPI.GatewaySessionControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures
  import Portal.GatewayFixtures
  import Portal.GatewaySessionFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)

    %{
      account: account,
      actor: actor,
      site: site,
      gateway: gateway
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, ~p"/gateway_sessions")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all gateway sessions", %{
      conn: conn,
      actor: actor,
      account: account,
      site: site,
      gateway: gateway
    } do
      sessions =
        for _ <- 1..3,
            do: gateway_session_fixture(account: account, site: site, gateway: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/gateway_sessions")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      # 3 from fixture + 1 from gateway_fixture's default session
      assert count == 4
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"])
      session_ids = Enum.map(sessions, & &1.id)

      for id <- session_ids do
        assert id in data_ids
      end
    end

    test "filters by gateway_id", %{
      conn: conn,
      actor: actor,
      account: account,
      site: site,
      gateway: gateway
    } do
      # Create sessions for target gateway
      target_sessions =
        for _ <- 1..2,
            do: gateway_session_fixture(account: account, site: site, gateway: gateway)

      # Create session for a different gateway
      other_gateway = gateway_fixture(account: account, site: site)

      _other_session =
        gateway_session_fixture(account: account, site: site, gateway: other_gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/gateway_sessions", gateway_id: gateway.id)

      assert %{
               "data" => data,
               "metadata" => %{"count" => count}
             } = json_response(conn, 200)

      # 2 from fixture + 1 from gateway_fixture's default session
      assert count == 3

      data_ids = Enum.map(data, & &1["id"])
      target_ids = Enum.map(target_sessions, & &1.id)

      for id <- target_ids do
        assert id in data_ids
      end
    end

    test "lists with limit", %{
      conn: conn,
      actor: actor,
      account: account,
      site: site,
      gateway: gateway
    } do
      for _ <- 1..3,
          do: gateway_session_fixture(account: account, site: site, gateway: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/gateway_sessions", limit: "2")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert length(data) == 2
      assert limit == 2
      # 3 from fixture + 1 from gateway_fixture's default session
      assert count == 4
      refute is_nil(next_page)
      assert is_nil(prev_page)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      site: site,
      gateway: gateway
    } do
      session = gateway_session_fixture(account: account, site: site, gateway: gateway)
      conn = get(conn, ~p"/gateway_sessions/#{session.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single gateway session", %{
      conn: conn,
      actor: actor,
      account: account,
      site: site,
      gateway: gateway
    } do
      session = gateway_session_fixture(account: account, site: site, gateway: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/gateway_sessions/#{session.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == session.id
      assert data["gateway_id"] == session.gateway_id
      assert data["gateway_token_id"] == session.gateway_token_id
    end

    test "returns not found for non-existent session", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/gateway_sessions/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
    end
  end
end
