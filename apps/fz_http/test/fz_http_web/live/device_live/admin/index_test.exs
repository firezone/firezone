defmodule FzHttpWeb.DeviceLive.Admin.IndexTest do
  use FzHttpWeb.ConnCase, async: false

  describe "authenticated/device list" do
    setup :create_devices

    test "includes the device details in the list", %{admin_conn: conn, devices: devices} do
      path = Routes.device_admin_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      assert html =~ "Latest Handshake"

      for device <- devices do
        assert html =~ device.name
      end
    end

    test "includes the user in the list", %{admin_conn: conn, devices: devices} do
      path = Routes.device_admin_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      assert html =~ "User"

      devices = FzHttp.Repo.preload(devices, :user)

      for device <- devices do
        assert html =~ device.user.email
        assert html =~ ~s[href="/users/#{device.user.id}"]
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

  describe "unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.device_admin_index_path(conn, :index)
      expected_path = Routes.root_path(conn, :index)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
