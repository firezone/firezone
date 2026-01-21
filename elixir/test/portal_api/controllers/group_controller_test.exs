defmodule PortalAPI.GroupControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Group

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

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
      groups = for _ <- 1..3, do: group_fixture(account: account)

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
      groups = for _ <- 1..3, do: group_fixture(account: account)

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
      group = group_fixture(account: account)
      conn = get(conn, "/groups/#{group.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single actor group", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => group.id,
                 "name" => group.name,
                 "entity_type" => "group",
                 "directory_id" => nil,
                 "idp_id" => nil,
                 "last_synced_at" => nil,
                 "inserted_at" => DateTime.to_iso8601(group.inserted_at),
                 "updated_at" => DateTime.to_iso8601(group.updated_at)
               }
             }
    end

    test "returns a synced group with directory_id and idp_id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = synced_group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => group.id,
                 "name" => group.name,
                 "entity_type" => "group",
                 "directory_id" => group.directory_id,
                 "idp_id" => group.idp_id,
                 "last_synced_at" => DateTime.to_iso8601(group.last_synced_at),
                 "inserted_at" => DateTime.to_iso8601(group.inserted_at),
                 "updated_at" => DateTime.to_iso8601(group.updated_at)
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
                   "reason" => "Unprocessable Content",
                   "validation_errors" => %{"name" => ["can't be blank"]}
                 }
               }
    end

    test "creates an actor group with valid attrs", %{conn: conn, actor: actor} do
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

    test "ignores protected fields on create", %{conn: conn, actor: actor} do
      attrs = %{
        "name" => "Test Group",
        "idp_id" => "should-be-ignored",
        "directory_id" => "00000000-0000-0000-0000-000000000000",
        "entity_type" => "org_unit",
        "last_synced_at" => "2024-01-01T00:00:00Z"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/groups", group: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["name"] == attrs["name"]
      assert resp["data"]["idp_id"] == nil
      assert resp["data"]["directory_id"] == nil
      assert resp["data"]["entity_type"] == "group"
      assert resp["data"]["last_synced_at"] == nil
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      group = group_fixture(account: account)
      conn = put(conn, "/groups/#{group.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error when attempting to edit a synced group", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account, idp_id: "external-group-id")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}", group: %{"name" => "New Name"})

      assert json_response(conn, 403) == %{
               "error" => %{"reason" => "Cannot update a synced Group"}
             }
    end

    test "updates an actor group", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

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
      group = group_fixture(account: account)
      conn = delete(conn, "/groups/#{group.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes an actor group", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/groups/#{group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => group.id,
                 "name" => group.name,
                 "entity_type" => "group",
                 "directory_id" => nil,
                 "idp_id" => nil,
                 "last_synced_at" => nil,
                 "inserted_at" => DateTime.to_iso8601(group.inserted_at),
                 "updated_at" => DateTime.to_iso8601(group.updated_at)
               }
             }

      refute Repo.get_by(Group, id: group.id, account_id: group.account_id)
    end
  end
end
