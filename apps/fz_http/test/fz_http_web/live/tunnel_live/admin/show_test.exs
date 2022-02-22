defmodule FzHttpWeb.TunnelLive.Admin.ShowTest do
  use FzHttpWeb.ConnCase, async: true

  describe "authenticated" do
    setup :create_tunnel

    @valid_params %{"tunnel" => %{"name" => "new_name"}}
    @invalid_params %{"tunnel" => %{"name" => ""}}
    @allowed_ips "2.2.2.2"
    @allowed_ips_change %{
      "tunnel" => %{"use_site_allowed_ips" => "false", "allowed_ips" => @allowed_ips}
    }
    @allowed_ips_unchanged %{
      "tunnel" => %{"use_site_allowed_ips" => "true", "allowed_ips" => @allowed_ips}
    }
    @dns "8.8.8.8, 8.8.4.4"
    @dns_change %{
      "tunnel" => %{"use_site_dns" => "false", "dns" => @dns}
    }
    @dns_unchanged %{
      "tunnel" => %{"use_site_dns" => "true", "dns" => @dns}
    }
    @wireguard_endpoint "6.6.6.6"
    @endpoint_change %{
      "tunnel" => %{"use_site_endpoint" => "false", "endpoint" => @wireguard_endpoint}
    }
    @endpoint_unchanged %{
      "tunnel" => %{"use_site_endpoint" => "true", "endpoint" => @wireguard_endpoint}
    }
    @mtu_change %{
      "tunnel" => %{"use_site_mtu" => "false", "mtu" => "1280"}
    }
    @mtu_unchanged %{
      "tunnel" => %{"use_site_mtu" => "true", "mtu" => "1280"}
    }
    @persistent_keepalive_change %{
      "tunnel" => %{
        "use_site_persistent_keepalive" => "false",
        "persistent_keepalive" => "120"
      }
    }
    @persistent_keepalive_unchanged %{
      "tunnel" => %{"use_site_persistent_keepalive" => "true", "persistent_keepalive" => "5"}
    }
    @default_allowed_ips_change %{
      "tunnel" => %{"use_site_allowed_ips" => "false"}
    }
    @default_dns_change %{
      "tunnel" => %{"use_site_dns" => "false"}
    }
    @default_endpoint_change %{
      "tunnel" => %{"use_site_endpoint" => "false"}
    }
    @default_mtu_change %{
      "tunnel" => %{"use_site_mtu" => "false"}
    }
    @default_persistent_keepalive_change %{
      "tunnel" => %{"use_site_persistent_keepalive" => "false"}
    }

    test "shows tunnel details", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :show, tunnel)
      {:ok, _view, html} = live(conn, path)
      assert html =~ "#{tunnel.name}"
      assert html =~ "<h4 class=\"title is-4\">Details</h4>"
    end

    test "opens modal", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :show, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Edit")
      |> render_click()

      assert_patched(view, Routes.tunnel_admin_show_path(conn, :edit, tunnel))
    end

    test "allows name changes", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-tunnel")
      |> render_submit(@valid_params)

      flash = assert_redirected(view, Routes.tunnel_admin_show_path(conn, :show, tunnel))
      assert flash["info"] == "Tunnel updated successfully."
    end

    test "prevents allowed_ips changes when use_site_allowed_ips is true ", %{
      authed_conn: conn,
      tunnel: tunnel
    } do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_submit(@allowed_ips_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents dns changes when use_site_dns is true", %{
      authed_conn: conn,
      tunnel: tunnel
    } do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_submit(@dns_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents endpoint changes when use_site_endpoint is true", %{
      authed_conn: conn,
      tunnel: tunnel
    } do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_submit(@endpoint_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents mtu changes when use_site_mtu is true", %{
      authed_conn: conn,
      tunnel: tunnel
    } do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_submit(@mtu_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents persistent_keepalive changes when use_site_persistent_keepalive is true",
         %{
           authed_conn: conn,
           tunnel: tunnel
         } do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_submit(@persistent_keepalive_unchanged)

      assert test_view =~ "must not be present"
    end

    test "allows allowed_ips changes", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-tunnel")
      |> render_submit(@allowed_ips_change)

      flash = assert_redirected(view, Routes.tunnel_admin_show_path(conn, :show, tunnel))
      assert flash["info"] == "Tunnel updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ @allowed_ips
    end

    test "allows dns changes", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-tunnel")
      |> render_submit(@dns_change)

      flash = assert_redirected(view, Routes.tunnel_admin_show_path(conn, :show, tunnel))
      assert flash["info"] == "Tunnel updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ @dns
    end

    test "allows endpoint changes", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-tunnel")
      |> render_submit(@endpoint_change)

      flash = assert_redirected(view, Routes.tunnel_admin_show_path(conn, :show, tunnel))
      assert flash["info"] == "Tunnel updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ @wireguard_endpoint
    end

    test "allows mtu changes", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-tunnel")
      |> render_submit(@mtu_change)

      flash = assert_redirected(view, Routes.tunnel_admin_show_path(conn, :show, tunnel))
      assert flash["info"] == "Tunnel updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "1280"
    end

    test "allows persistent_keepalive changes", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-tunnel")
      |> render_submit(@persistent_keepalive_change)

      flash = assert_redirected(view, Routes.tunnel_admin_show_path(conn, :show, tunnel))
      assert flash["info"] == "Tunnel updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "120"
    end

    test "prevents empty names", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_submit(@invalid_params)

      assert test_view =~ "can&#39;t be blank"
    end

    test "on use_site_allowed_ips change", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_change(@default_allowed_ips_change)

      assert test_view =~ """
             <input class="input " id="edit-tunnel_allowed_ips" name="tunnel[allowed_ips]" type="text"/>\
             """
    end

    test "on use_site_dns change", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_change(@default_dns_change)

      assert test_view =~ """
             <input class="input " id="edit-tunnel_dns" name="tunnel[dns]" type="text"/>\
             """
    end

    test "on use_site_endpoint change", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_change(@default_endpoint_change)

      assert test_view =~ """
             <input class="input " id="edit-tunnel_endpoint" name="tunnel[endpoint]" type="text"/>\
             """
    end

    test "on use_site_mtu change", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_change(@default_mtu_change)

      assert test_view =~ """
             <input class="input " id="edit-tunnel_mtu" name="tunnel[mtu]" type="text"/>\
             """
    end

    test "on use_site_persistent_keepalive change", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :edit, tunnel)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-tunnel")
        |> render_change(@default_persistent_keepalive_change)

      assert test_view =~ """
             <input class="input " id="edit-tunnel_persistent_keepalive" name="tunnel[persistent_keepalive]" type="text"/>\
             """
    end
  end

  describe "delete own tunnel" do
    setup :create_tunnel

    test "successful", %{authed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :show, tunnel)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Delete Tunnel #{tunnel.name}")
      |> render_click()

      _flash = assert_redirected(view, Routes.tunnel_admin_index_path(conn, :index))
    end
  end

  describe "unauthenticated" do
    setup :create_tunnel

    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn, tunnel: tunnel} do
      path = Routes.tunnel_admin_show_path(conn, :show, tunnel)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  # XXX: Revisit this when RBAC is more fleshed out. Admins can now view other admins' tunnels.
  # describe "authenticated as other user" do
  #   setup [:create_tunnel, :create_other_user_tunnel]
  #
  #   test "mount redirects to session path", %{
  #     authed_conn: conn,
  #     tunnel: _tunnel,
  #     other_tunnel: other_tunnel
  #   } do
  #     path = Routes.tunnel_admin_show_path(conn, :show, other_tunnel)
  #     expected_path = Routes.session_path(conn, :new)
  #     assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
  #   end
  # end
end
