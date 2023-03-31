defmodule FzHttpWeb.DeviceLive.Unprivileged.ShowTest do
  use FzHttpWeb.ConnCase, async: true

  describe "unauthenticated" do
    setup :create_device

    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn, device: device} do
      path = ~p"/devices/#{device}"
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated" do
    setup :create_unprivileged_device

    test "includes the device details", %{unprivileged_conn: conn, device: device} do
      path = ~p"/user_devices/#{device}"
      {:ok, _view, html} = live(conn, path)

      assert html =~ device.name
      assert html =~ "Latest Handshake"
    end

    test "deletes the device", %{unprivileged_conn: conn, device: device} do
      path = ~p"/user_devices/#{device}"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#delete-device-button")
      |> render_click()

      {new_path, _flash} = assert_redirect(view)
      assert new_path == ~p"/user_devices"
    end
  end

  describe "authenticated; device management disabled" do
    test "prevents deleting a device", %{
      unprivileged_user: user,
      unprivileged_conn: conn
    } do
      {:ok, device: device} = create_device(user: user)

      FzHttp.Config.put_config!(:allow_unprivileged_device_management, false)

      path = ~p"/user_devices/#{device}"
      expected_path = ~p"/"

      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
