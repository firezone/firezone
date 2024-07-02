defmodule API.ResourceControllerTest do
  use API.ConnCase, async: true
  alias Domain.Resources.Resource

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
      conn = get(conn, "/v1/resources")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "lists all resources", %{conn: conn, account: account, actor: actor} do
      resources = for _ <- 1..3, do: Fixtures.Resources.create_resource(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/resources")

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
      resource_ids = Enum.map(resources, & &1.id) |> MapSet.new()

      assert MapSet.equal?(data_ids, resource_ids)
    end

    test "lists resources with limit", %{conn: conn, account: account, actor: actor} do
      resources = for _ <- 1..3, do: Fixtures.Resources.create_resource(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/resources", limit: "2")

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
      resource_ids = Enum.map(resources, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, resource_ids)
    end
  end

  describe "show" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = Fixtures.Resources.create_resource(%{account: account})
      conn = get(conn, "/v1/resources/#{resource.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns a single resource", %{conn: conn, account: account, actor: actor} do
      resource = Fixtures.Resources.create_resource(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/resources/#{resource.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "address" => resource.address,
                 "description" => resource.address_description,
                 "id" => resource.id,
                 "name" => resource.name,
                 "type" => Atom.to_string(resource.type)
               }
             }
    end
  end

  describe "create" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/v1/resources", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns errors on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/resources", resource: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "errors" => %{
                   "address" => ["can't be blank"],
                   "connections" => ["can't be blank"],
                   "name" => ["can't be blank"],
                   "type" => ["can't be blank"]
                 }
               }
    end

    test "creates a resource with valid attrs", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      attrs = %{
        "address" => "google.com",
        "name" => "Google",
        "type" => "dns",
        "connections" => [
          %{"gateway_group_id" => gateway_group.id}
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/resources", resource: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["address"] == attrs["address"]
      assert resp["data"]["description"] == nil
      assert resp["data"]["name"] == attrs["name"]
      assert resp["data"]["type"] == attrs["type"]
    end
  end

  describe "update" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = Fixtures.Resources.create_resource(%{account: account})
      conn = put(conn, "/v1/resources/#{resource.id}", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "updates a resource", %{conn: conn, account: account, actor: actor} do
      resource = Fixtures.Resources.create_resource(%{account: account})

      attrs = %{"name" => "Google"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/v1/resources/#{resource.id}", resource: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["address"] == resource.address
      assert resp["data"]["description"] == resource.address_description
      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "delete" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = Fixtures.Resources.create_resource(%{account: account})
      conn = delete(conn, "/v1/resources/#{resource.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "deletes a resource", %{conn: conn, account: account, actor: actor} do
      resource = Fixtures.Resources.create_resource(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/v1/resources/#{resource.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "address" => resource.address,
                 "description" => resource.address_description,
                 "id" => resource.id,
                 "name" => resource.name,
                 "type" => Atom.to_string(resource.type)
               }
             }

      assert {:error, :not_found} ==
               Resource.Query.not_deleted()
               |> Resource.Query.by_id(resource.id)
               |> Repo.fetch(Resource.Query)
    end
  end
end
