defmodule FzHttpWeb.DeviceLive.ShowTest do
  # XXX: Enabling async causes deadlocks. Figure out why.
  use FzHttpWeb.ConnCase, async: false

  describe "authenticated" do
    setup :create_device

    @valid_params %{"device" => %{"name" => "new_name"}}
    @invalid_params %{"device" => %{"name" => ""}}
    @allowed_ips "2.2.2.2"
    @allowed_ips_change %{
      "device" => %{"use_default_allowed_ips" => "false", "allowed_ips" => @allowed_ips}
    }
    @allowed_ips_unchanged %{
      "device" => %{"use_default_allowed_ips" => "true", "allowed_ips" => @allowed_ips}
    }
    @dns_servers "8.8.8.8, 8.8.4.4"
    @dns_servers_change %{
      "device" => %{"use_default_dns_servers" => "false", "dns_servers" => @dns_servers}
    }
    @dns_servers_unchanged %{
      "device" => %{"use_default_dns_servers" => "true", "dns_servers" => @dns_servers}
    }
    @wireguard_endpoint "6.6.6.6"
    @endpoint_change %{
      "device" => %{"use_default_endpoint" => "false", "endpoint" => @wireguard_endpoint}
    }
    @endpoint_unchanged %{
      "device" => %{"use_default_endpoint" => "true", "endpoint" => @wireguard_endpoint}
    }
    @persistent_keepalives_change %{
      "device" => %{
        "use_default_persistent_keepalives" => "false",
        "persistent_keepalives" => "120"
      }
    }
    @persistent_keepalives_unchanged %{
      "device" => %{"use_default_persistent_keepalives" => "true", "persistent_keepalives" => "5"}
    }
    @default_allowed_ips_change %{
      "device" => %{"use_default_allowed_ips" => "false"}
    }
    @default_dns_servers_change %{
      "device" => %{"use_default_dns_servers" => "false"}
    }
    @default_endpoint_change %{
      "device" => %{"use_default_endpoint" => "false"}
    }
    @default_persistent_keepalives_change %{
      "device" => %{"use_default_persistent_keepalives" => "false"}
    }

    test "shows device details", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, _view, html} = live(conn, path)
      assert html =~ "#{device.name}"
      assert html =~ "<h4 class=\"title is-4\">Details</h4>"
    end

    test "opens modal", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Edit")
      |> render_click()

      assert_patched(view, Routes.device_show_path(conn, :edit, device))
    end

    test "allows name changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@valid_params)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."
    end

    test "prevents allowed_ips changes when use_default_allowed_ips is true ", %{
      authed_conn: conn,
      device: device
    } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@allowed_ips_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents dns_servers changes when use_default_dns_servers is true", %{
      authed_conn: conn,
      device: device
    } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@dns_servers_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents endpoint changes when use_default_endpoint is true", %{
      authed_conn: conn,
      device: device
    } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@endpoint_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents persistent_keepalives changes when use_default_persistent_keepalives is true",
         %{
           authed_conn: conn,
           device: device
         } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@persistent_keepalives_unchanged)

      assert test_view =~ "must not be present"
    end

    test "allows allowed_ips changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@allowed_ips_change)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "AllowedIPs = #{@allowed_ips}"
    end

    test "allows dns_servers changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@dns_servers_change)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "DNS = #{@dns_servers}"
    end

    test "allows endpoint changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@endpoint_change)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Endpoint = #{@wireguard_endpoint}:51820"
    end

    test "allows persistent_keepalives changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@persistent_keepalives_change)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "PersistentKeepalive = 120"
    end

    test "prevents empty names", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@invalid_params)

      assert test_view =~ "can&#39;t be blank"
    end

    test "on use_default_allowed_ips change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_allowed_ips_change)

      assert test_view =~ """
             <input class="input" id="edit-device_allowed_ips" name="device[allowed_ips]" type="text"/>\
             """
    end

    test "on use_default_dns_servers change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_dns_servers_change)

      assert test_view =~ """
             <input class="input" id="edit-device_dns_servers" name="device[dns_servers]" type="text"/>\
             """
    end

    test "on use_default_endpoint change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_endpoint_change)

      assert test_view =~ """
             <input class="input" id="edit-device_endpoint" name="device[endpoint]" type="text"/>\
             """
    end

    test "on use_default_persistent_keepalives change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_persistent_keepalives_change)

      assert test_view =~ """
             <input class="input" id="edit-device_persistent_keepalives" name="device[persistent_keepalives]" type="text"/>\
             """
    end
  end

  describe "delete own device" do
    setup :create_device

    test "successful", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Delete Device #{device.name}")
      |> render_click()

      _flash = assert_redirected(view, Routes.device_index_path(conn, :index))
    end
  end

  describe "unauthenticated" do
    setup :create_device

    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  # XXX: Revisit this when RBAC is more fleshed out. Admins can now view other admins' devices.
  # describe "authenticated as other user" do
  #   setup [:create_device, :create_other_user_device]
  #
  #   test "mount redirects to session path", %{
  #     authed_conn: conn,
  #     device: _device,
  #     other_device: other_device
  #   } do
  #     path = Routes.device_show_path(conn, :show, other_device)
  #     expected_path = Routes.session_path(conn, :new)
  #     assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
  #   end
  # end
end
