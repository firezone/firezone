defmodule PortalAPI.MembershipControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      group = group_fixture(account: account)
      conn = get(conn, "/groups/#{group.id}/memberships")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all memberships", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)

      memberships =
        for _ <- 1..3,
            do: membership_fixture(account: account, group: group)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}/memberships")

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
      membership_ids = Enum.map(memberships, & &1.actor_id)

      assert equal_ids?(membership_ids, data_ids)
    end

    test "lists identity providers with limit", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      memberships =
        for _ <- 1..3,
            do: membership_fixture(account: account, group: group)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}/memberships", limit: "2")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert limit == 2
      assert count == 3
      refute is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      assert MapSet.size(data_ids) == 2

      membership_ids =
        Enum.map(memberships, & &1.actor_id) |> MapSet.new()

      assert MapSet.subset?(data_ids, membership_ids)
    end
  end

  describe "update_patch/2" do
    test "adds actor to group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor = actor_fixture(account: account)
      attrs = %{"add" => [actor.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor.id]}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid group id", %{conn: conn, actor: api_actor} do
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/00000000-0000-0000-0000-000000000000/memberships",
          memberships: attrs
        )

      assert resp = json_response(conn, 404)
      assert resp == %{"error" => %{"reason" => "Not Found"}}
    end

    test "returns error on invalid actor id", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert resp = json_response(conn, 422)
      assert %{"error" => %{"reason" => "Unprocessable Content"}} = resp
      assert %{"error" => %{"validation_errors" => %{"memberships" => memberships}}} = resp
      assert [%{"actor" => ["does not exist"]}] = memberships
    end

    test "removes actor from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = %{"remove" => [actor2.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor1.id]}
    end

    test "adds and removes actors from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      actor3 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = %{"add" => [actor3.id], "remove" => [actor2.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor3.id])
    end

    test "group remains the same on empty params", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = %{}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor2.id])
    end
  end

  describe "update_put/2" do
    test "adds actor to group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor = actor_fixture(account: account)
      attrs = [%{"actor_id" => actor.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor.id]}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "removes actor from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = [%{"actor_id" => actor1.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor1.id]}
    end

    test "adds and removes actors from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      actor3 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = [%{"actor_id" => actor1.id}, %{"actor_id" => actor3.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor3.id])
    end
  end
end
