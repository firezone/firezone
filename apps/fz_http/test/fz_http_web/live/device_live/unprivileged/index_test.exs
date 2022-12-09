defmodule FzHttpWeb.DeviceLive.Unprivileged.IndexTest do
  use FzHttpWeb.ConnCase, async: true

  describe "authenticated/device list" do
    test "includes the device name in the list", %{
      unprivileged_user: user,
      unprivileged_conn: conn
    } do
      {:ok, devices: devices} = create_devices(user_id: user.id)

      path = ~p"/user_devices"
      {:ok, _view, html} = live(conn, path)

      for device <- devices do
        assert html =~ device.name
      end
    end
  end

  describe "authenticated but user deleted" do
    test "redirects to not authorized", %{admin_conn: conn} do
      path = ~p"/devices"
      clear_users()
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated device management disabled" do
    setup do
      stub_conf(:allow_unprivileged_device_management, false)
      :ok
    end

    test "prevents navigating to /user_devices/new", %{unprivileged_conn: conn} do
      path = ~p"/user_devices/new"
      expected_path = ~p"/"

      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end

    test "omits Add Device button", %{unprivileged_conn: conn} do
      path = ~p"/user_devices"
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Add Device"
    end
  end

  describe "authenticated device configuration disabled" do
    setup do
      stub_conf(:allow_unprivileged_device_configuration, false)
      :ok
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
      path = ~p"/user_devices/new"
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
      path = ~p"/user_devices/new"
      {:ok, _view, html} = live(conn, path)

      for field <- fields do
        assert html =~ "device[#{field}]"
      end
    end

    @tag params: %{"device" => %{"public_key" => "test-pubkey", "name" => "test-tunnel"}},
         error: "ipv4 address pool is exhausted. Increase network size or remove some devices."
    test "Displays base error when IPv4 pool is exhausted",
         %{params: params, unprivileged_conn: conn, error: error} do
      path = ~p"/user_devices/new"
      {:ok, view, _html} = live(conn, path)

      # A pool of size 1 is always exhausted
      stub_app_env(:wireguard_ipv4_network, "10.0.0.1/32")

      assert view
             |> element("#create-device")
             |> render_submit(params) =~ error
    end

    @tag params: %{"device" => %{"public_key" => "test-pubkey", "name" => "test-tunnel"}},
         error: "ipv6 address pool is exhausted. Increase network size or remove some devices."
    test "Displays base error when IPv6 pool is exhausted",
         %{params: params, unprivileged_conn: conn, error: error} do
      path = ~p"/user_devices/new"
      {:ok, view, _html} = live(conn, path)

      # A pool of size 1 is always exhausted
      stub_app_env(:wireguard_ipv6_network, "fd00::3:2:0/128")

      assert view
             |> element("#create-device")
             |> render_submit(params) =~ error
    end
  end

  describe "authenticated/creates device" do
    test "shows new form", %{unprivileged_conn: conn} do
      path = ~p"/user_devices"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Add Device")
      |> render_click()

      assert_patch(view, ~p"/user_devices/new")
    end

    test "creates device", %{unprivileged_conn: conn} do
      path = ~p"/user_devices/new"
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
      path = ~p"/user_devices"
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
