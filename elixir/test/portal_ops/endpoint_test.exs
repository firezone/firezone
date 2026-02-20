defmodule PortalOps.EndpointTest do
  use Portal.DataCase, async: true
  import Plug.Test

  describe "LiveDashboard routes" do
    test "GET /dashboard redirects to /dashboard/home" do
      conn =
        conn(:get, "/dashboard")
        |> PortalOps.Endpoint.call([])

      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["/dashboard/home"]
    end

    test "GET /dashboard/home returns 200" do
      conn =
        conn(:get, "/dashboard/home")
        |> PortalOps.Endpoint.call([])

      assert conn.status == 200
      assert conn.resp_body =~ "Dashboard"
    end
  end
end
