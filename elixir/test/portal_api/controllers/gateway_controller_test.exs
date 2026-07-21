defmodule PortalAPI.GatewayControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Device

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures
  import Portal.DeviceFixtures

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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns 400 for invalid UUID site_id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/null/gateways")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
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

    test "returns error for invalid page cursor", %{conn: conn, actor: actor, site: site} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{site.id}/gateways", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} =
               json_response(conn, 400)
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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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
                 "ipv4" => Portal.Types.IP.to_string(gateway.ipv4),
                 "ipv6" => Portal.Types.IP.to_string(gateway.ipv6),
                 "online" => false,
                 "public_key" => gateway.public_key,
                 "last_seen_at" => DateTime.to_iso8601(gateway.last_seen_at),
                 "last_seen_version" => gateway.last_seen_version,
                 "last_seen_user_agent" => gateway.last_seen_user_agent,
                 "last_seen_remote_ip" => Portal.Types.IP.to_string(gateway.last_seen_remote_ip),
                 "last_seen_remote_ip_location_region" =>
                   gateway.last_seen_remote_ip_location_region,
                 "last_seen_remote_ip_location_city" =>
                   gateway.last_seen_remote_ip_location_city,
                 "last_seen_remote_ip_location_lat" => gateway.last_seen_remote_ip_location_lat,
                 "last_seen_remote_ip_location_lon" => gateway.last_seen_remote_ip_location_lon
               }
             }
    end

    test "returns not found for non-existent gateway", %{conn: conn, actor: actor, site: site} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/sites/#{site.id}/gateways/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns unauthorized when subject may not delete the gateway", %{
      conn: conn,
      account: account,
      site: site
    } do
      gateway = gateway_fixture(account: account, site: site)
      unprivileged_actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged_actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/gateways/#{gateway.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == gateway.id
      assert data["name"] == gateway.name
      assert data["online"] == false

      refute Repo.get_by(Device, id: gateway.id, account_id: gateway.account_id)
    end

    test "returns not found for non-existent gateway", %{conn: conn, actor: actor, site: site} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/gateways/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end
end
