defmodule API.GroupControllerTest do
  use API.ConnCase, async: true
  alias Domain.Group

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/groups")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all groups", %{conn: conn, account: account, actor: actor} do
      groups = for _ <- 1..3, do: Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups")

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
      group_ids = Enum.map(groups, & &1.id)

      assert equal_ids?(data_ids, group_ids)
    end

    test "lists groups with limit", %{conn: conn, account: account, actor: actor} do
      groups = for _ <- 1..3, do: Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups", limit: "2")

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
      group_ids = Enum.map(groups, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, group_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      group = Fixtures.Actors.create_group(%{account: account})
      conn = get(conn, "/groups/#{group.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single actor group", %{conn: conn, account: account, actor: actor} do
      group = Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => group.id,
                 "name" => group.name
               }
             }
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/groups", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/groups")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/groups", group: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "error" => %{
                   "reason" => "Unprocessable Entity",
                   "validation_errors" => %{"name" => ["can't be blank"]}
                 }
               }
    end

    test "creates an actor group  with valid attrs", %{conn: conn, actor: actor} do
      attrs = %{
        "name" => "Test Group"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/groups", group: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      group = Fixtures.Actors.create_group(%{account: account})
      conn = put(conn, "/groups/#{group.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      group = Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "updates an actor group", %{conn: conn, account: account, actor: actor} do
      group = Fixtures.Actors.create_group(%{account: account})

      attrs = %{"name" => "Updated Group"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}", group: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["id"] == group.id
      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      group = Fixtures.Actors.create_group(%{account: account})
      conn = delete(conn, "/groups/#{group.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes an actor group", %{conn: conn, account: account, actor: actor} do
      group = Fixtures.Actors.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/groups/#{group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => group.id,
                 "name" => group.name
               }
             }

      refute Repo.get(Group, group.id)
    end
  end
end
