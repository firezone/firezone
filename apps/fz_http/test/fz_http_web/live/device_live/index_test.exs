defmodule FzHttpWeb.DeviceLive.IndexTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.{Devices, Devices.Device}

  describe "authenticated/device list" do
    setup :create_devices

    test "includes the device name in the list", %{authed_conn: conn, devices: devices} do
      path = Routes.device_index_path(conn, :index)
      {:ok, _view, html} = live(conn, path)

      for device <- devices do
        assert html =~ device.name
      end
    end
  end

  describe "authenticated but user deleted" do
    setup [:create_user]

    test "redirects to not authorized", %{authed_conn: conn} do
      path = Routes.device_index_path(conn, :index)
      clear_users()
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated/creates device" do
    test "creates device", %{authed_conn: conn} do
      path = Routes.device_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Add Device")
      |> render_click()

      device = Devices.list_devices() |> List.first()

      assert %Device{} = device
      assert_redirected(view, Routes.device_show_path(conn, :show, device))
    end
  end

  describe "unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.device_index_path(conn, :index)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
