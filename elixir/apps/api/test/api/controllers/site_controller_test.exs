defmodule API.SiteControllerTest do
  use API.ConnCase, async: true
  alias Domain.Site
  alias Domain.Tokens.Token

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
      conn = get(conn, "/sites")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all sites", %{conn: conn, account: account, actor: actor} do
      sites = for _ <- 1..3, do: Fixtures.Sites.create_site(%{account: account})

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
      sites = for _ <- 1..3, do: Fixtures.Sites.create_site(%{account: account})

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
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = Fixtures.Sites.create_site(%{account: account})
      conn = get(conn, "/sites/#{site.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single site", %{conn: conn, account: account, actor: actor} do
      site = Fixtures.Sites.create_site(%{account: account})

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
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/sites", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{"name" => String.duplicate("a", 65)}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites", site: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "error" => %{
                   "reason" => "Unprocessable Entity",
                   "validation_errors" => %{"name" => ["should be at most 64 character(s)"]}
                 }
               }
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
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = Fixtures.Sites.create_site(%{account: account})
      conn = put(conn, "/sites/#{site.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      site = Fixtures.Sites.create_site(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{site.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "updates a site", %{conn: conn, account: account, actor: actor} do
      site = Fixtures.Sites.create_site(%{account: account})

      attrs = %{"name" => "Updated Site Name"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/sites/#{site.id}", site: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = Fixtures.Sites.create_site(%{account: account})
      conn = delete(conn, "/sites/#{site.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a site", %{conn: conn, account: account, actor: actor} do
      site = Fixtures.Sites.create_site(%{account: account})

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

      refute Repo.get(Site, site.id)
    end
  end

  describe "site token create/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = Fixtures.Sites.create_site(%{account: account})
      conn = post(conn, "/sites/#{site.id}/tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "creates a gateway token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = Fixtures.Sites.create_site(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/tokens")

      assert %{"data" => %{"id" => _id, "token" => _token}} = json_response(conn, 201)
    end
  end

  describe "delete single gateway token" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = Fixtures.Sites.create_site(%{account: account})
      token = Fixtures.Sites.create_token(%{account: account, group: site})
      conn = delete(conn, "/sites/#{site.id}/tokens/#{token.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes gateway token", %{conn: conn, account: account, actor: actor} do
      site = Fixtures.Sites.create_site(%{account: account})
      token = Fixtures.Sites.create_token(%{account: account, group: site})

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/sites/#{site.id}/tokens/#{token.id}")

      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)

      refute Repo.get(Token, token.id)
    end
  end

  describe "delete all gateway tokens" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = Fixtures.Sites.create_site(%{account: account})
      conn = delete(conn, "/sites/#{site.id}/tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes all gateway tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = Fixtures.Sites.create_site(%{account: account})

      tokens =
        for _ <- 1..3,
            do: Fixtures.Sites.create_token(%{account: account, group: site})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/tokens")

      assert %{"data" => %{"deleted_count" => 3}} = json_response(conn, 200)

      Enum.map(tokens, fn token ->
        refute Repo.get(Token, token.id)
      end)
    end
  end
end
