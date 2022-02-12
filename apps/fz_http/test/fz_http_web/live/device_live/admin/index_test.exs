defmodule FzHttpWeb.DeviceLive.Admin.IndexTest do
  use FzHttpWeb.ConnCase, async: false

  # alias FzHttp.Devices

  describe "authenticated/device list" do
    setup :create_devices

    test "includes the device name in the list", %{authed_conn: conn, devices: devices} do
      path = Routes.device_admin_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      for device <- devices do
        assert html =~ device.name
      end
    end
  end

  describe "authenticated but user deleted" do
    setup [:create_user]

    test "redirects to not authorized", %{authed_conn: conn} do
      path = Routes.device_admin_index_path(conn, :index)
      clear_users()
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.device_admin_index_path(conn, :index)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
