defmodule API.GatewayGroupControllerTest do
  use API.ConnCase, async: true
  alias Domain.Gateways.Group

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/v1/gateway_groups")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "lists all gateway groups", %{conn: conn, account: account, actor: actor} do
      gateway_groups = for _ <- 1..3, do: Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/gateway_groups")

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

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      gateway_group_ids = Enum.map(gateway_groups, & &1.id) |> MapSet.new()

      assert MapSet.equal?(data_ids, gateway_group_ids)
    end

    test "lists gateway groups with limit", %{conn: conn, account: account, actor: actor} do
      gateway_groups = for _ <- 1..3, do: Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/gateway_groups", limit: "2")

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
      gateway_group_ids = Enum.map(gateway_groups, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, gateway_group_ids)
    end
  end

  describe "show" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = get(conn, "/v1/gateway_groups/#{gateway_group.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns a single gateway_group", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/gateway_groups/#{gateway_group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway_group.id,
                 "name" => gateway_group.name
               }
             }
    end
  end

  describe "create" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/v1/gateway_groups", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns errors on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{"name" => String.duplicate("a", 65)}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/gateway_groups", gateway_group: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "errors" => %{
                   "name" => ["should be at most 64 character(s)"]
                 }
               }
    end

    test "creates a gateway group with valid attrs", %{conn: conn, actor: actor} do
      attrs = %{
        "name" => "Example Site"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/gateway_groups", gateway_group: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "update" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = put(conn, "/v1/gateway_groups/#{gateway_group.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "updates a gateway group", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      attrs = %{"name" => "Updated Site Name"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/v1/gateway_groups/#{gateway_group.id}", gateway_group: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "delete" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = delete(conn, "/v1/gateway_groups/#{gateway_group.id}", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "deletes a gateway group", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/v1/gateway_groups/#{gateway_group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway_group.id,
                 "name" => gateway_group.name
               }
             }

      assert {:error, :not_found} ==
               Group.Query.not_deleted()
               |> Group.Query.by_id(gateway_group.id)
               |> Repo.fetch(Group.Query)
    end
  end
end
