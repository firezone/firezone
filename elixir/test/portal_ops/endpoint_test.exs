defmodule PortalOps.EndpointTest do
  use Portal.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  defp with_basic_auth(conn) do
    username = Application.fetch_env!(:portal, :ops_admin_username)
    password = Application.fetch_env!(:portal, :ops_admin_password)
    encoded = Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", "Basic #{encoded}")
  end

  describe "LiveDashboard routes" do
    test "GET /dashboard returns 401 without credentials" do
      conn =
        conn(:get, "/dashboard")
        |> PortalOps.Endpoint.call([])

      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
    end

    test "GET /dashboard redirects to /dashboard/home with valid credentials" do
      conn =
        conn(:get, "/dashboard")
        |> with_basic_auth()
        |> PortalOps.Endpoint.call([])

      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["/dashboard/home"]
    end

    test "GET /dashboard/home returns 200 with valid credentials" do
      conn =
        conn(:get, "/dashboard/home")
        |> with_basic_auth()
        |> PortalOps.Endpoint.call([])

      assert conn.status == 200
      assert conn.resp_body =~ "Dashboard"
    end
  end
end
