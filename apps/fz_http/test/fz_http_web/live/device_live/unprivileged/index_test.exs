defmodule FzHttpWeb.DeviceLive.Unprivileged.IndexTest do
  use FzHttpWeb.ConnCase, async: false

  describe "authenticated/device list" do
    test "includes the device name in the list", %{
      unprivileged_user: user,
      unprivileged_conn: conn
    } do
      {:ok, devices: devices} = create_devices(user_id: user.id)

      path = Routes.device_unprivileged_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      for device <- devices do
        assert html =~ device.name
      end
    end
  end

  describe "authenticated but user deleted" do
    test "redirects to not authorized", %{admin_conn: conn} do
      path = Routes.device_admin_index_path(conn, :index)
      clear_users()
      expected_path = Routes.root_path(conn, :index)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated device management disabled" do
    setup do
      restore_env(:allow_unprivileged_device_management, false, &on_exit/1)
    end

    test "omits Add Device button", %{unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Add Device"
    end

    test "prevents creating a device", %{unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#create-device")
      |> render_submit(%{"device" => %{"public_key" => "test-pubkey", "name" => "test-tunnel"}})

      flash = assert_redirected(view, "/")
      assert flash["error"] == "Not authorized."
    end
  end

  describe "authenticated device configuration disabled" do
    setup do
      restore_env(:allow_unprivileged_device_configuration, false, &on_exit/1)
    end

    @tag fields: ~w(
      use_site_allowed_ips
      allowed_ips
      use_site_dns
      dns
      use_site_endpoint
      endpoint
      use_site_mtu
      mtu
      use_site_persistent_keepalive
      persistent_keepalive
      ipv4
      ipv6
    )
    test "hides the customization fields", %{fields: fields, unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :new)
      {:ok, _view, html} = live(conn, path)

      for field <- fields do
        refute html =~ "device[#{field}]"
      end
    end

    @tag fields: ~w(
      name
      description
      public_key
      preshared_key
    )
    test "renders the needed fields", %{fields: fields, unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :new)
      {:ok, _view, html} = live(conn, path)

      for field <- fields do
        assert html =~ "device[#{field}]"
      end
    end

    @tag params: %{"device" => %{"public_key" => "test-pubkey", "name" => "test-tunnel"}},
         error: "ipv4 address pool is exhausted. Increase network size or remove some devices."
    test "Displays base error when IPv4 pool is exhausted",
         %{params: params, unprivileged_conn: conn, error: error} do
      path = Routes.device_unprivileged_index_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      # A pool of size 1 is always exhausted
      restore_env(:wireguard_ipv4_network, "10.0.0.1/32", &on_exit/1)

      assert view
             |> element("#create-device")
             |> render_submit(params) =~ error
    end

    @tag params: %{"device" => %{"public_key" => "test-pubkey", "name" => "test-tunnel"}},
         error: "ipv6 address pool is exhausted. Increase network size or remove some devices."
    test "Displays base error when IPv6 pool is exhausted",
         %{params: params, unprivileged_conn: conn, error: error} do
      path = Routes.device_unprivileged_index_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      # A pool of size 1 is always exhausted
      restore_env(:wireguard_ipv6_network, "fd00::3:2:0/128", &on_exit/1)

      assert view
             |> element("#create-device")
             |> render_submit(params) =~ error
    end
  end

  describe "authenticated/creates device" do
    test "shows new form", %{unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      new_view =
        view
        |> element("a", "Add Device")
        |> render_click()

      assert_redirected(view, Routes.device_unprivileged_index_path(conn, :new))
    end

    test "creates device", %{unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      new_view =
        view
        |> element("#create-device")
        |> render_submit(%{"device" => %{"public_key" => "test-pubkey", "name" => "test-tunnel"}})

      assert new_view =~ "Device added!"
    end
  end

  describe "unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.device_admin_index_path(conn, :index)
      expected_path = Routes.root_path(conn, :index)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
