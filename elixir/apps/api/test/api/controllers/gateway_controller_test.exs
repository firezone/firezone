defmodule API.GatewayControllerTest do
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

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, gateway_group: gateway_group} do
      conn = get(conn, "/gateway_groups/#{gateway_group.id}/gateways")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
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

      other_group = Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_gateway(%{account: account, group: other_group})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/gateway_groups/#{gateway_group.id}/gateways")

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
      gateway_ids = Enum.map(gateways, & &1.id)

      assert equal_ids?(data_ids, gateway_ids)
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
        |> get("/gateway_groups/#{gateway_group.id}/gateways", limit: "2")

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

  describe "show/2" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      gateway_group: gateway_group
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})
      conn = get(conn, "/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
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
        |> get("/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway.id,
                 "name" => gateway.name,
                 "ipv4" => Domain.Types.IP.to_string(gateway.ipv4),
                 "ipv6" => Domain.Types.IP.to_string(gateway.ipv6),
                 "online" => false
               }
             }
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      gateway_group: gateway_group
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})
      conn = delete(conn, "/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
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
        |> delete("/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway.id,
                 "name" => gateway.name,
                 "ipv4" => Domain.Types.IP.to_string(gateway.ipv4),
                 "ipv6" => Domain.Types.IP.to_string(gateway.ipv6),
                 "online" => false
               }
             }

      refute Repo.get(Gateway, gateway.id)
    end
  end
end
