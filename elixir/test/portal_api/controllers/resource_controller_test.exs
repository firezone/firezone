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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error for invalid page cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} =
               json_response(conn, 400)
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

    test "filters by exact name match", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account, name: "postgres-prod")
      _other = resource_fixture(account: account, name: "postgres-staging")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", name: "postgres-prod")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by type", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account, type: :dns, address: "app.example.com")
      _other = resource_fixture(account: account, type: :cidr)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", type: "dns")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by type cidr", %{conn: conn, account: account, actor: actor} do
      resource = cidr_resource_fixture(account: account)
      _other = resource_fixture(account: account, type: :dns, address: "app.example.com")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", type: "cidr")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by type ip", %{conn: conn, account: account, actor: actor} do
      resource = ip_resource_fixture(account: account)
      _other = resource_fixture(account: account, type: :dns, address: "app.example.com")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", type: "ip")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by type static_device_pool", %{conn: conn, account: account, actor: actor} do
      resource = static_device_pool_resource_fixture(account: account)
      _other = resource_fixture(account: account, type: :dns, address: "app.example.com")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", type: "static_device_pool")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by site_id", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site, type: :ip, address: "10.0.0.5")
      _other = resource_fixture(account: account, type: :ip, address: "10.0.0.6")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", site_id: site.id)

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by exact address match", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account, type: :ip, address: "10.0.0.10")
      _other = resource_fixture(account: account, type: :ip, address: "10.0.0.11")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", address: "10.0.0.10")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "filters by ip_stack", %{conn: conn, account: account, actor: actor} do
      resource =
        resource_fixture(account: account, type: :dns, address: "app.example.com", ip_stack: :dual)

      _other =
        resource_fixture(
          account: account,
          type: :dns,
          address: "other.example.com",
          ip_stack: :ipv4_only
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", ip_stack: "dual")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == resource.id
    end

    test "rejects an invalid type filter value", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", type: "bogus")

      assert %{"status" => 400} = json_response(conn, 400)
    end

    test "rejects an invalid ip_stack filter value", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", ip_stack: "bogus")

      assert %{"status" => 400} = json_response(conn, 400)
    end

    test "rejects a malformed site_id filter value", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources", site_id: "not-a-uuid")

      assert %{"status" => 400} = json_response(conn, 400)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = resource_fixture(account: account)
      conn = get(conn, "/resources/#{resource.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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
                 "ip_stack" => "ipv4_only",
                 "filters" => []
               }
             }
    end

    test "returns filters in the response", %{conn: conn, account: account, actor: actor} do
      resource =
        resource_with_filters_fixture(%{account: account, type: :ip, address: "10.0.0.9"})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{resource.id}")

      assert %{"data" => %{"filters" => filters}} = json_response(conn, 200)

      assert filters == [
               %{"protocol" => "tcp", "ports" => ["80", "443"]},
               %{"protocol" => "udp", "ports" => ["53"]}
             ]
    end

    test "returns not found when resource does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/resources", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => %{
                 "name" => ["can't be blank"],
                 "type" => ["can't be blank"]
               }
             } = json_response(conn, 422)
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
      assert resp["data"]["site_id"] == site.id
    end

    # Device pools are deliberately not creatable through the API for now -
    # see PortalAPI.ResourceController.Database.reject_device_pool_type/1.
    # If pool creation is re-enabled, this test should go back to asserting
    # a 201 with a null address and no site_id.
    test "returns 422 when an addressed type has no address", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources",
          resource: %{"name" => "No address", "type" => "dns", "address" => nil, "site_id" => site.id}
        )

      assert %{"status" => 422, "validation_errors" => %{"address" => ["can't be blank"]}} =
               json_response(conn, 422)
    end

    test "rejects creating a static device pool", %{
      conn: conn,
      actor: actor
    } do
      attrs = %{
        "name" => "Shared Devices",
        "type" => "static_device_pool"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert resp = json_response(conn, 422)
      assert resp["validation_errors"]["type"] == ["is invalid"]
    end

    test "creates a resource with filters for Starter accounts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      account = update_account(account, metadata: %{stripe: %{product_name: "Starter"}})
      site = site_fixture(account: account)

      attrs = %{
        "address" => "10.0.0.10",
        "name" => "Prod DB",
        "type" => "ip",
        "site_id" => site.id,
        "filters" => [%{"protocol" => "tcp", "ports" => ["5432"]}]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert resp = json_response(conn, 201)
      assert resp["data"]["filters"] == [%{"protocol" => "tcp", "ports" => ["5432"]}]
    end

    test "returns 422 when creating a resource in the Internet Site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = internet_site_fixture(account: account)

      attrs = %{
        "address" => "google.com",
        "name" => "Google",
        "type" => "dns",
        "site_id" => site.id
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => %{
                 "site_id" => ["cannot be the Internet Site"]
               }
             } = json_response(conn, 422)

      assert Portal.Repo.aggregate(Resource, :count) == 0
    end

    test "returns 422 when creating an internet resource in a regular Site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      attrs = %{
        "name" => "Internet",
        "type" => "internet",
        "site_id" => site.id
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/resources", resource: attrs)

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => %{
                 "site_id" => ["must be the Internet Site for an Internet Resource"]
               }
             } = json_response(conn, 422)

      assert Portal.Repo.aggregate(Resource, :count) == 0
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = resource_fixture(account: account)
      conn = put(conn, "/resources/#{resource.id}", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
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

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "preserves filters when filters are omitted", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      resource =
        resource_with_filters_fixture(%{
          account: account,
          site: site,
          type: :ip,
          address: "10.0.0.9"
        })

      assert length(resource.filters) == 2

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: %{"name" => "Renamed"})

      assert resp = json_response(conn, 200)
      assert resp["data"]["name"] == "Renamed"

      reloaded = Portal.Repo.get_by!(Resource, id: resource.id, account_id: account.id)
      assert length(reloaded.filters) == 2
    end

    test "replaces filters when filters are provided", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      resource =
        resource_with_filters_fixture(%{
          account: account,
          site: site,
          type: :ip,
          address: "10.0.0.9"
        })

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}",
          resource: %{"filters" => [%{"protocol" => "tcp", "ports" => ["8080"]}]}
        )

      assert %{"data" => %{"filters" => [%{"protocol" => "tcp", "ports" => ["8080"]}]}} =
               json_response(conn, 200)

      reloaded = Portal.Repo.get_by!(Resource, id: resource.id, account_id: account.id)
      assert [%{protocol: :tcp}] = reloaded.filters
    end

    test "clears filters when an empty list is provided", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      resource =
        resource_with_filters_fixture(%{
          account: account,
          site: site,
          type: :ip,
          address: "10.0.0.9"
        })

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: %{"filters" => []})

      assert json_response(conn, 200)

      reloaded = Portal.Repo.get_by!(Resource, id: resource.id, account_id: account.id)
      assert reloaded.filters == []
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

    test "returns error when updating internet resource", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = internet_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: %{"name" => "New Name"})

      assert %{
               "type" => "about:blank",
               "status" => 403,
               "detail" => "Internet Resource cannot be modified"
             } = json_response(conn, 403)
    end

    test "returns 422 when moving a resource to the Internet Site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      internet_site = internet_site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: %{"site_id" => internet_site.id})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => %{
                 "site_id" => ["cannot be the Internet Site"]
               }
             } = json_response(conn, 422)

      reloaded = Portal.Repo.get_by!(Resource, id: resource.id, account_id: account.id)
      assert reloaded.site_id == site.id
    end

    test "returns 422 when changing a resource to the internet type", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: %{"type" => "internet"})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => %{
                 "site_id" => ["must be the Internet Site for an Internet Resource"]
               }
             } = json_response(conn, 422)

      reloaded = Portal.Repo.get_by!(Resource, id: resource.id, account_id: account.id)
      assert reloaded.type == :dns
    end

    # Converting an existing Resource to a pool is creation by another
    # name, so the same guard covers update.
    test "rejects converting a resource to the static_device_pool type", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)
      resource = dns_resource_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}", resource: %{"type" => "static_device_pool"})

      assert resp = json_response(conn, 422)
      assert resp["validation_errors"]["type"] == ["device pools cannot be created via the API"]

      assert Repo.get_by!(Portal.Resource, account_id: account.id, id: resource.id).type == :dns
    end

    # An existing pool - created in the admin portal - stays fully
    # manageable; only creating one is blocked.
    test "allows updating an existing static device pool", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}", resource: %{"name" => "Renamed Pool"})

      assert resp = json_response(conn, 200)
      assert resp["data"]["name"] == "Renamed Pool"
      assert resp["data"]["type"] == "static_device_pool"
    end

    # The guard keys off the type *changing*, not off its value, so a PUT
    # that restates a pool's own type is not a transition and is allowed.
    # Clients that echo the full resource back on update depend on this.
    test "allows an update that restates an existing pool's own type", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}",
          resource: %{"name" => "Restated Pool", "type" => "static_device_pool"}
        )

      assert resp = json_response(conn, 200)
      assert resp["data"]["name"] == "Restated Pool"
      assert resp["data"]["type"] == "static_device_pool"
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = resource_fixture(account: account)
      conn = delete(conn, "/resources/#{resource.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns not found when resource does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/resources/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
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
                 "ip_stack" => Atom.to_string(resource.ip_stack),
                 "filters" => []
               }
             }

      refute Repo.get_by(Resource, id: resource.id, account_id: resource.account_id)
    end

    test "returns error when deleting internet resource", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = internet_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/resources/#{resource.id}")

      assert %{
               "type" => "about:blank",
               "status" => 403,
               "detail" => "Internet Resource cannot be modified"
             } = json_response(conn, 403)

      assert Repo.get_by(Resource, id: resource.id, account_id: resource.account_id)
    end
  end
end
