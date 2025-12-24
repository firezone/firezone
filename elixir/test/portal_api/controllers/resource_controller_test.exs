defmodule PortalAPI.ResourceControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Resource

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :api_client, account: account)
    subject = subject_fixture(actor: actor, account: account)

    %{
      account: account,
      actor: actor,
      subject: subject
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/resources")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all resources", %{conn: conn, account: account, actor: actor} do
      resources = for _ <- 1..3, do: resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources")

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
      resource_ids = Enum.map(resources, & &1.id)

      assert equal_ids?(data_ids, resource_ids)
    end

    test "lists resources with limit", %{conn: conn, account: account, actor: actor} do
      resources = for _ <- 1..3, do: resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", limit: "2")

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

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = resource_fixture(account: account)
      conn = get(conn, "/resources/#{resource.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single resource", %{conn: conn, account: account, actor: actor} do
      resource = dns_resource_fixture(account: account, ip_stack: :ipv4_only)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{resource.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "address" => resource.address,
                 "address_description" => resource.address_description,
                 "id" => resource.id,
                 "name" => resource.name,
                 "type" => Atom.to_string(resource.type),
                 "ip_stack" => "ipv4_only"
               }
             }
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/resources", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "error" => %{
                   "reason" => "Unprocessable Content",
                   "validation_errors" => %{
                     "site_id" => ["can't be blank"],
                     "name" => ["can't be blank"],
                     "type" => ["can't be blank"]
                   }
                 }
               }
    end

    test "creates a resource with valid attrs", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      attrs = %{
        "address" => "google.com",
        "name" => "Google",
        "type" => "dns",
        "ip_stack" => "ipv6_only",
        "site_id" => site.id
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["address"] == attrs["address"]
      assert resp["data"]["address_description"] == nil
      assert resp["data"]["name"] == attrs["name"]
      assert resp["data"]["type"] == attrs["type"]
      assert resp["data"]["ip_stack"] == attrs["ip_stack"]
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = resource_fixture(account: account)
      conn = put(conn, "/resources/#{resource.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns not found when resource does not exist", %{
      conn: conn,
      actor: actor
    } do
      attrs = %{"name" => "Google"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{Ecto.UUID.generate()}", resource: attrs)

      assert resp = json_response(conn, 404)
      assert resp == %{"error" => %{"reason" => "Not Found"}}
    end

    test "updates a resource", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)

      attrs = %{"name" => "Google", "ip_stack" => "ipv6_only"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["address"] == resource.address
      assert resp["data"]["address_description"] == resource.address_description
      assert resp["data"]["name"] == attrs["name"]
      assert resp["data"]["ip_stack"] == attrs["ip_stack"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = resource_fixture(account: account)
      conn = delete(conn, "/resources/#{resource.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a resource", %{conn: conn, account: account, actor: actor} do
      resource = dns_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/resources/#{resource.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "address" => resource.address,
                 "address_description" => resource.address_description,
                 "id" => resource.id,
                 "name" => resource.name,
                 "type" => Atom.to_string(resource.type),
                 "ip_stack" => Atom.to_string(resource.ip_stack)
               }
             }

      refute Repo.get_by(Resource, id: resource.id, account_id: resource.account_id)
    end
  end
end
