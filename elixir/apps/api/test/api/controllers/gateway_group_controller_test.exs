defmodule API.GatewayGroupControllerTest do
  use API.ConnCase, async: true
  alias Domain.Gateways.Group
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
      conn = get(conn, "/gateway_groups")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all gateway groups", %{conn: conn, account: account, actor: actor} do
      gateway_groups = for _ <- 1..3, do: Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/gateway_groups")

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
      gateway_group_ids = Enum.map(gateway_groups, & &1.id)

      assert equal_ids?(data_ids, gateway_group_ids)
    end

    test "lists gateway groups with limit", %{conn: conn, account: account, actor: actor} do
      gateway_groups = for _ <- 1..3, do: Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/gateway_groups", limit: "2")

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

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = get(conn, "/gateway_groups/#{gateway_group.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single gateway_group", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/gateway_groups/#{gateway_group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway_group.id,
                 "name" => gateway_group.name
               }
             }
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/gateway_groups", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/gateway_groups")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{"name" => String.duplicate("a", 65)}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/gateway_groups", gateway_group: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "error" => %{
                   "reason" => "Unprocessable Entity",
                   "validation_errors" => %{"name" => ["should be at most 64 character(s)"]}
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
        |> post("/gateway_groups", gateway_group: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = put(conn, "/gateway_groups/#{gateway_group.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/gateway_groups/#{gateway_group.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "updates a gateway group", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      attrs = %{"name" => "Updated Site Name"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/gateway_groups/#{gateway_group.id}", gateway_group: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = delete(conn, "/gateway_groups/#{gateway_group.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a gateway group", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/gateway_groups/#{gateway_group.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway_group.id,
                 "name" => gateway_group.name
               }
             }

      refute Repo.get(Group, gateway_group.id)
    end
  end

  describe "gateway group token create/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = post(conn, "/gateway_groups/#{gateway_group.id}/tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "creates a gateway token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/gateway_groups/#{gateway_group.id}/tokens")

      assert %{"data" => %{"id" => _id, "token" => _token}} = json_response(conn, 201)
    end
  end

  describe "delete single gateway token" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      token = Fixtures.Gateways.create_token(%{account: account, group: gateway_group})
      conn = delete(conn, "/gateway_groups/#{gateway_group.id}/tokens/#{token.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes gateway token", %{conn: conn, account: account, actor: actor} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      token = Fixtures.Gateways.create_token(%{account: account, group: gateway_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/gateway_groups/#{gateway_group.id}/tokens/#{token.id}")

      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)

      refute Repo.get(Token, token.id)
    end
  end

  describe "delete all gateway tokens" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})
      conn = delete(conn, "/gateway_groups/#{gateway_group.id}/tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes all gateway tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      gateway_group = Fixtures.Gateways.create_group(%{account: account})

      tokens =
        for _ <- 1..3,
            do: Fixtures.Gateways.create_token(%{account: account, group: gateway_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/gateway_groups/#{gateway_group.id}/tokens")

      assert %{"data" => %{"deleted_count" => 3}} = json_response(conn, 200)

      Enum.map(tokens, fn token ->
        refute Repo.get(Token, token.id)
      end)
    end
  end
end
