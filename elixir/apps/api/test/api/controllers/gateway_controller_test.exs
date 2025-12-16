defmodule API.GatewayControllerTest do
  use API.ConnCase, async: true
  alias Domain.Gateway

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.SiteFixtures
  import Domain.GatewayFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    site = site_fixture(account: account)

    %{
      account: account,
      actor: actor,
      site: site
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, site: site} do
      conn = get(conn, "/sites/#{site.id}/gateways")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all gateways for a site", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      gateways =
        for _ <- 1..3,
            do: gateway_fixture(account: account, site: site)

      other_site = site_fixture(account: account)
      gateway_fixture(account: account, site: other_site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{site.id}/gateways")

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
      site: site
    } do
      gateways =
        for _ <- 1..3,
            do: gateway_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{site.id}/gateways", limit: "2")

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
      site: site
    } do
      gateway = gateway_fixture(account: account, site: site)
      conn = get(conn, "/sites/#{site.id}/gateways/#{gateway.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      gateway = gateway_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{site.id}/gateways/#{gateway.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway.id,
                 "name" => gateway.name,
                 "ipv4" => Domain.Types.IP.to_string(gateway.ipv4_address.address),
                 "ipv6" => Domain.Types.IP.to_string(gateway.ipv6_address.address),
                 "online" => false
               }
             }
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      site: site
    } do
      gateway = gateway_fixture(account: account, site: site)
      conn = delete(conn, "/sites/#{site.id}/gateways/#{gateway.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      gateway = gateway_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/gateways/#{gateway.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => gateway.id,
                 "name" => gateway.name,
                 "ipv4" => Domain.Types.IP.to_string(gateway.ipv4_address.address),
                 "ipv6" => Domain.Types.IP.to_string(gateway.ipv6_address.address),
                 "online" => false
               }
             }

      refute Repo.get_by(Gateway, id: gateway.id, account_id: gateway.account_id)
    end
  end
end
