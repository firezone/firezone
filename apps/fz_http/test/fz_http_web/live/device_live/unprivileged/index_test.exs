defmodule FzHttpWeb.DeviceLive.Unprivileged.IndexTest do
  use FzHttpWeb.ConnCase, async: false

  # alias FzHttp.{Devices, Devices.Device}

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
    test "redirects to not authorized", %{authed_conn: conn} do
      path = Routes.device_admin_index_path(conn, :index)
      clear_users()
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated/creates device" do
    test "creates device", %{unprivileged_conn: conn} do
      path = Routes.device_unprivileged_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      new_view =
        view
        |> element("a", "Add Device")
        |> render_click()

      assert_patched(view, Routes.device_unprivileged_index_path(conn, :new))
      assert new_view =~ "Device Added!"
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
