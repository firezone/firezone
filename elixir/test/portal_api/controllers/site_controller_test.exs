defmodule PortalAPI.SiteControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Site

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/sites")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns error for invalid page cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} = json_response(conn, 400)
    end

    test "lists all sites", %{conn: conn, account: account, actor: actor} do
      sites = for _ <- 1..3, do: site_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites")

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
      site_ids = Enum.map(sites, & &1.id)

      assert equal_ids?(data_ids, site_ids)
    end

    test "lists sites with limit", %{conn: conn, account: account, actor: actor} do
      sites = for _ <- 1..3, do: site_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites", limit: "2")

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
      site_ids = Enum.map(sites, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, site_ids)
    end

    test "lists sites with page_cursor", %{conn: conn, account: account, actor: actor} do
      sites = for _ <- 1..3, do: site_fixture(account: account)

      first_page =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites", limit: "2")

      assert %{"metadata" => %{"next_page" => next_page}} = json_response(first_page, 200)
      refute is_nil(next_page)

      second_page =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites", page_cursor: next_page)

      assert %{
               "data" => data,
               "metadata" => %{
                 "prev_page" => prev_page
               }
             } = json_response(second_page, 200)

      refute is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      site_ids = Enum.map(sites, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, site_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(account: account)
      conn = get(conn, "/sites/#{site.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns 400 for invalid UUID id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/null")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} = json_response(conn, 400)
    end

    test "returns a single site", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{site.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => site.id,
                 "name" => site.name
               }
             }
    end

    test "returns not found when site does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} = json_response(conn, 404)
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/sites", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} = json_response(conn, 400)
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{"name" => String.duplicate("a", 65)}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites", site: attrs)

      assert %{
               "status" => 422,
               "validation_errors" => %{"name" => ["should be at most 64 character(s)"]}
             } = json_response(conn, 422)
    end

    test "creates a site with valid attrs", %{conn: conn, actor: actor} do
      attrs = %{
        "name" => "Example Site"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites", site: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["name"] == attrs["name"]
    end

    test "returns error when sites limit is reached", %{conn: conn, account: account, actor: actor} do
      Ecto.Changeset.change(account, limits: %Portal.Accounts.Limits{sites_count: 0})
      |> Repo.update!()

      attrs = %{"name" => "Example Site"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites", site: attrs)

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Sites limit reached"} = json_response(conn, 403)
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = put(conn, "/sites/#{site.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{site.id}")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} = json_response(conn, 400)
    end

    test "returns not found when site does not exist", %{conn: conn, actor: actor} do
      attrs = %{"name" => "Updated Site Name"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{Ecto.UUID.generate()}", site: attrs)

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} = json_response(conn, 404)
    end

    test "updates a site", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})

      attrs = %{"name" => "Updated Site Name"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{site.id}", site: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["name"] == attrs["name"]
    end

    test "keeps current name when name is omitted", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{site.id}", site: %{})

      assert resp = json_response(conn, 200)
      assert resp["data"]["name"] == site.name
    end

    test "returns error when updating system managed site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = internet_site_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{site.id}", site: %{"name" => "New Name"})

      assert %{"type" => "about:blank", "status" => 403, "detail" => "System managed Site cannot be modified"} =
               json_response(conn, 403)
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = delete(conn, "/sites/#{site.id}", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns not found when site does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} = json_response(conn, 404)
    end

    test "deletes a site", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => site.id,
                 "name" => site.name
               }
             }

      refute Repo.get_by(Site, id: site.id, account_id: site.account_id)
    end

    test "returns error when deleting system managed site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = internet_site_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}")

      assert %{"type" => "about:blank", "status" => 403, "detail" => "System managed Site cannot be modified"} =
               json_response(conn, 403)

      assert Repo.get_by(Site, id: site.id, account_id: site.account_id)
    end
  end
end
