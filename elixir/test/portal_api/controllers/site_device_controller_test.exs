defmodule PortalAPI.SiteDeviceControllerTest do
  use PortalAPI.ConnCase, async: true

  alias Portal.{Device, SiteDevice}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteDeviceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    site = site_fixture(account: account)
    other_site = site_fixture(account: account)

    %{account: account, actor: actor, site: site, other_site: other_site}
  end

  defp assigned?(account, site, device) do
    not is_nil(
      Repo.get_by(SiteDevice, account_id: account.id, site_id: site.id, device_id: device.id)
    )
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn, site: site} do
      conn = post(conn, "/sites/#{site.id}/devices", device: %{id: Ecto.UUID.generate()})
      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "assigns a gateway of another site to the site", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      other_site: other_site
    } do
      gateway = gateway_fixture(account: account, site: other_site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/devices", device: %{id: gateway.id})

      assert %{"data" => %{"id" => id, "name" => name}} = json_response(conn, 201)
      assert id == gateway.id
      assert name == gateway.name
      assert get_resp_header(conn, "location") == ["/sites/#{site.id}/gateways/#{gateway.id}"]
      assert assigned?(account, site, gateway)
      assert assigned?(account, other_site, gateway)
    end

    test "assigns a client, which serves once it reports it routes", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      client = client_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/devices", device: %{id: client.id})

      assert %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert id == client.id
      assert assigned?(account, site, client)
    end

    test "returns 409 when the gateway is already assigned", %{
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
        |> post("/sites/#{site.id}/devices", device: %{id: gateway.id})

      assert %{"status" => 409} = json_response(conn, 409)
    end

    test "returns 404 for a device of another account", %{conn: conn, actor: actor, site: site} do
      gateway = gateway_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/devices", device: %{id: gateway.id})

      assert %{"status" => 404} = json_response(conn, 404)
    end

    test "returns 400 without a device", %{conn: conn, actor: actor, site: site} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/devices", %{})

      assert %{"status" => 400} = json_response(conn, 400)
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, site: site} do
      conn = delete(conn, "/sites/#{site.id}/devices/#{Ecto.UUID.generate()}")
      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "removes a gateway from a site it was added to", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      other_site: other_site
    } do
      gateway = gateway_fixture(account: account, site: other_site)
      site_device_fixture(site: site, device: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/devices/#{gateway.id}")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == gateway.id
      refute assigned?(account, site, gateway)
      assert assigned?(account, other_site, gateway)
      assert Repo.get_by(Device, account_id: account.id, id: gateway.id)
    end

    test "moves the gateway's home site when removing it", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      other_site: other_site
    } do
      gateway = gateway_fixture(account: account, site: site)
      site_device_fixture(site: other_site, device: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/devices/#{gateway.id}")

      assert json_response(conn, 200)
      refute assigned?(account, site, gateway)
      assert Repo.get_by!(Device, account_id: account.id, id: gateway.id).site_id == other_site.id
    end

    test "returns 409 for the gateway's only site", %{
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
        |> delete("/sites/#{site.id}/devices/#{gateway.id}")

      assert %{"status" => 409, "detail" => detail} = json_response(conn, 409)
      assert detail =~ "only Site"
      assert assigned?(account, site, gateway)
    end

    test "returns 404 when the gateway is not assigned to the site", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      other_site: other_site
    } do
      gateway = gateway_fixture(account: account, site: other_site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/devices/#{gateway.id}")

      assert %{"status" => 404} = json_response(conn, 404)
    end
  end
end
