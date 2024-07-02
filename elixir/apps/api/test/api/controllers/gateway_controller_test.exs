defmodule API.GatewayControllerTest do
  alias API.Gateway
  alias API.Gateway
  alias API.Gateway
  use API.ConnCase, async: true
  alias Domain.Gateways.Gateway

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
    gateway_group = Fixtures.Gateways.create_group(%{account: account})

    %{
      account: account,
      actor: actor,
      gateway_group: gateway_group
    }
  end

  describe "index" do
    test "returns error when not authorized", %{conn: conn, gateway_group: gateway_group} do
      conn = post(conn, "/v1/gateway_groups/#{gateway_group.id}/gateways")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "lists all gateways for a gateway group", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway_group: gateway_group
    } do
      gateways =
        for _ <- 1..3,
            do: Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/gateway_groups/#{gateway_group.id}/gateways")

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
      gateway_ids = Enum.map(gateways, & &1.id) |> MapSet.new()

      assert MapSet.equal?(data_ids, gateway_ids)
    end

    test "lists gateways with limit", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway_group: gateway_group
    } do
      gateways =
        for _ <- 1..3,
            do: Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/gateway_groups/#{gateway_group.id}/gateways", limit: "2")

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
      gateway_ids = Enum.map(gateways, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, gateway_ids)
    end
  end

  describe "show" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      gateway_group: gateway_group
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})
      conn = get(conn, "/v1/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns a single gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway_group: gateway_group
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway.id,
                 "name" => gateway.name,
                 "ipv4" => Domain.Types.IP.to_string(gateway.ipv4),
                 "ipv6" => Domain.Types.IP.to_string(gateway.ipv6)
               }
             }
    end
  end

  describe "create gateway token" do
    test "returns error when not authorized", %{conn: conn, gateway_group: gateway_group} do
      conn = post(conn, "/v1/gateway_groups/#{gateway_group.id}/gateways")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "creates a gateway token", %{
      conn: conn,
      actor: actor,
      gateway_group: gateway_group
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/gateway_groups/#{gateway_group.id}/gateways")

      assert %{"data" => %{"gateway_token" => token}} = json_response(conn, 201)

      assert is_binary(token)
    end
  end

  describe "delete" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      gateway_group: gateway_group
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})
      conn = delete(conn, "/v1/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "deletes a gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      gateway_group: gateway_group
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/v1/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway.id,
                 "name" => gateway.name,
                 "ipv4" => Domain.Types.IP.to_string(gateway.ipv4),
                 "ipv6" => Domain.Types.IP.to_string(gateway.ipv6)
               }
             }

      assert {:error, :not_found} ==
               Gateway.Query.not_deleted()
               |> Gateway.Query.by_id(gateway.id)
               |> Repo.fetch(Gateway.Query)
    end
  end
end
