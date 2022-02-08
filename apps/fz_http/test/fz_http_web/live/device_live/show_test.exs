defmodule FzHttpWeb.DeviceLive.ShowTest do
  use FzHttpWeb.ConnCase, async: true

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
    @dns "8.8.8.8, 8.8.4.4"
    @dns_change %{
      "device" => %{"use_default_dns" => "false", "dns" => @dns}
    }
    @dns_unchanged %{
      "device" => %{"use_default_dns" => "true", "dns" => @dns}
    }
    @wireguard_endpoint "6.6.6.6"
    @endpoint_change %{
      "device" => %{"use_default_endpoint" => "false", "endpoint" => @wireguard_endpoint}
    }
    @endpoint_unchanged %{
      "device" => %{"use_default_endpoint" => "true", "endpoint" => @wireguard_endpoint}
    }
    @mtu_change %{
      "device" => %{"use_default_mtu" => "false", "mtu" => "1280"}
    }
    @mtu_unchanged %{
      "device" => %{"use_default_mtu" => "true", "mtu" => "1280"}
    }
    @persistent_keepalive_change %{
      "device" => %{
        "use_default_persistent_keepalive" => "false",
        "persistent_keepalive" => "120"
      }
    }
    @persistent_keepalive_unchanged %{
      "device" => %{"use_default_persistent_keepalive" => "true", "persistent_keepalive" => "5"}
    }
    @default_allowed_ips_change %{
      "device" => %{"use_default_allowed_ips" => "false"}
    }
    @default_dns_change %{
      "device" => %{"use_default_dns" => "false"}
    }
    @default_endpoint_change %{
      "device" => %{"use_default_endpoint" => "false"}
    }
    @default_mtu_change %{
      "device" => %{"use_default_mtu" => "false"}
    }
    @default_persistent_keepalive_change %{
      "device" => %{"use_default_persistent_keepalive" => "false"}
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

    test "prevents dns changes when use_default_dns is true", %{
      authed_conn: conn,
      device: device
    } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@dns_unchanged)

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

    test "prevents mtu changes when use_default_mtu is true", %{
      authed_conn: conn,
      device: device
    } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@mtu_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents persistent_keepalive changes when use_default_persistent_keepalive is true",
         %{
           authed_conn: conn,
           device: device
         } do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@persistent_keepalive_unchanged)

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

    test "allows dns changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@dns_change)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "DNS = #{@dns}"
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

    test "allows mtu changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@mtu_change)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."

      {:ok, _view, html} = live(conn, path)
      assert html =~ "MTU = 1280"
    end

    test "allows persistent_keepalive changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@persistent_keepalive_change)

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
             <input class="input " id="edit-device_allowed_ips" name="device[allowed_ips]" type="text"/>\
             """
    end

    test "on use_default_dns change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_dns_change)

      assert test_view =~ """
             <input class="input " id="edit-device_dns" name="device[dns]" type="text"/>\
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
             <input class="input " id="edit-device_endpoint" name="device[endpoint]" type="text"/>\
             """
    end

    test "on use_default_mtu change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_mtu_change)

      assert test_view =~ """
             <input class="input " id="edit-device_mtu" name="device[mtu]" type="text"/>\
             """
    end

    test "on use_default_persistent_keepalive change", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_change(@default_persistent_keepalive_change)

      assert test_view =~ """
             <input class="input " id="edit-device_persistent_keepalive" name="device[persistent_keepalive]" type="text"/>\
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
