defmodule API.ActorGroupMembershipControllerTest do
  use API.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      conn = get(conn, "/actor_groups/#{actor_group.id}/memberships")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all memberships", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})

      memberships =
        for _ <- 1..3,
            do: Fixtures.Actors.create_membership(%{account: account, group: actor_group})

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actor_groups/#{actor_group.id}/memberships")

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
      actor_group = Fixtures.Actors.create_group(%{account: account})

      memberships =
        for _ <- 1..3,
            do: Fixtures.Actors.create_membership(%{account: account, group: actor_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actor_groups/#{actor_group.id}/memberships", limit: "2")

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
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor = Fixtures.Actors.create_actor(%{account: account})
      attrs = %{"add" => [actor.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor.id]}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/#{actor_group.id}/memberships")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid group id", %{conn: conn, account: account, actor: api_actor} do
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/00000000-0000-0000-0000-000000000000/memberships",
          memberships: attrs
        )

      assert resp = json_response(conn, 404)
      assert resp == %{"error" => %{"reason" => "Not Found"}}
    end

    test "returns error on invalid actor id", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert resp = json_response(conn, 422)
      assert resp == %{"error" => %{"reason" => "Invalid payload"}}
    end

    test "removes actor from group", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor1 = Fixtures.Actors.create_actor(%{account: account})
      actor2 = Fixtures.Actors.create_actor(%{account: account})
      Fixtures.Actors.create_membership(%{account: account, actor: actor1, group: actor_group})
      Fixtures.Actors.create_membership(%{account: account, actor: actor2, group: actor_group})

      attrs = %{"remove" => [actor2.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor1.id]}
    end

    test "adds and removes actors from group", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor1 = Fixtures.Actors.create_actor(%{account: account})
      actor2 = Fixtures.Actors.create_actor(%{account: account})
      actor3 = Fixtures.Actors.create_actor(%{account: account})
      Fixtures.Actors.create_membership(%{account: account, actor: actor1, group: actor_group})
      Fixtures.Actors.create_membership(%{account: account, actor: actor2, group: actor_group})

      attrs = %{"add" => [actor3.id], "remove" => [actor2.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor3.id])
    end

    test "group remains the same on empty params", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor1 = Fixtures.Actors.create_actor(%{account: account})
      actor2 = Fixtures.Actors.create_actor(%{account: account})
      Fixtures.Actors.create_membership(%{account: account, actor: actor1, group: actor_group})
      Fixtures.Actors.create_membership(%{account: account, actor: actor2, group: actor_group})

      attrs = %{}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor2.id])
    end
  end

  describe "update_put/2" do
    test "adds actor to group", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor = Fixtures.Actors.create_actor(%{account: account})
      attrs = [%{"actor_id" => actor.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor.id]}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actor_groups/#{actor_group.id}/memberships")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "removes actor from group", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor1 = Fixtures.Actors.create_actor(%{account: account})
      actor2 = Fixtures.Actors.create_actor(%{account: account})
      Fixtures.Actors.create_membership(%{account: account, actor: actor1, group: actor_group})
      Fixtures.Actors.create_membership(%{account: account, actor: actor2, group: actor_group})

      attrs = [%{"actor_id" => actor1.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor1.id]}
    end

    test "adds and removes actors from group", %{conn: conn, account: account, actor: api_actor} do
      actor_group = Fixtures.Actors.create_group(%{account: account})
      actor1 = Fixtures.Actors.create_actor(%{account: account})
      actor2 = Fixtures.Actors.create_actor(%{account: account})
      actor3 = Fixtures.Actors.create_actor(%{account: account})
      Fixtures.Actors.create_membership(%{account: account, actor: actor1, group: actor_group})
      Fixtures.Actors.create_membership(%{account: account, actor: actor2, group: actor_group})

      attrs = [%{"actor_id" => actor1.id}, %{"actor_id" => actor3.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actor_groups/#{actor_group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor3.id])
    end
  end
end
