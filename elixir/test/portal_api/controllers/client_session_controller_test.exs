defmodule PortalAPI.ClientSessionControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.ClientSessionFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    client = client_fixture(account: account)

    %{
      account: account,
      actor: actor,
      client: client
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, ~p"/client_sessions")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all client sessions", %{
      conn: conn,
      actor: actor,
      account: account,
      client: client
    } do
      sessions =
        for _ <- 1..3,
            do: client_session_fixture(account: account, client: client)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/client_sessions")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert count == 3
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"])
      session_ids = Enum.map(sessions, & &1.id)
      assert equal_ids?(data_ids, session_ids)
    end

    test "filters by client_id", %{
      conn: conn,
      actor: actor,
      account: account,
      client: client
    } do
      # Create sessions for target client
      target_sessions =
        for _ <- 1..2,
            do: client_session_fixture(account: account, client: client)

      # Create session for a different client
      other_client = client_fixture(account: account)
      _other_session = client_session_fixture(account: account, client: other_client)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/client_sessions", client_id: client.id)

      assert %{
               "data" => data,
               "metadata" => %{"count" => count}
             } = json_response(conn, 200)

      assert count == 2

      data_ids = Enum.map(data, & &1["id"])
      target_ids = Enum.map(target_sessions, & &1.id)
      assert equal_ids?(data_ids, target_ids)
    end

    test "lists with limit", %{
      conn: conn,
      actor: actor,
      account: account,
      client: client
    } do
      for _ <- 1..3,
          do: client_session_fixture(account: account, client: client)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/client_sessions", limit: "2")

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
      assert count == 3
      refute is_nil(next_page)
      assert is_nil(prev_page)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account, client: client} do
      session = client_session_fixture(account: account, client: client)
      conn = get(conn, ~p"/client_sessions/#{session.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single client session", %{
      conn: conn,
      actor: actor,
      account: account,
      client: client
    } do
      session = client_session_fixture(account: account, client: client)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/client_sessions/#{session.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == session.id
      assert data["client_id"] == session.client_id
      assert data["client_token_id"] == session.client_token_id
    end

    test "returns not found for non-existent session", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/client_sessions/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
    end
  end
end
