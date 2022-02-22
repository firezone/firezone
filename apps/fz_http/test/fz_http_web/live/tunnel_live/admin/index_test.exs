defmodule FzHttpWeb.TunnelLive.Admin.IndexTest do
  use FzHttpWeb.ConnCase, async: false

  describe "authenticated/tunnel list" do
    setup :create_tunnels

    test "includes the tunnel name in the list", %{authed_conn: conn, tunnels: tunnels} do
      path = Routes.tunnel_admin_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      for tunnel <- tunnels do
        assert html =~ tunnel.name
      end
    end
  end

  describe "authenticated but user deleted" do
    test "redirects to not authorized", %{authed_conn: conn} do
      path = Routes.tunnel_admin_index_path(conn, :index)
      clear_users()
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.tunnel_admin_index_path(conn, :index)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
