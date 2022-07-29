defmodule FzHttpWeb.DeviceLive.Admin.ShowTest do
  use FzHttpWeb.ConnCase, async: true

  describe "unauthenticated" do
    setup :create_device

    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn, device: device} do
      path = Routes.device_admin_show_path(conn, :show, device)
      expected_path = Routes.root_path(conn, :index)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated" do
    setup :create_device

    test "includes the device details", %{admin_conn: conn, device: device} do
      path = Routes.device_admin_show_path(conn, :show, device)
      {:ok, _view, html} = live(conn, path)

      assert html =~ device.name
      assert html =~ "Latest Handshake"
    end

    test "deletes the device", %{admin_conn: conn, device: device} do
      path = Routes.device_admin_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#delete-device-button")
      |> render_click()

      {new_path, _flash} = assert_redirect(view)
      assert new_path == Routes.device_admin_index_path(conn, :index)
    end
  end

  # XXX: Revisit this when RBAC is more fleshed out. Admins can now view other admins' devices.
  # describe "authenticated as other user" do
  #   setup [:create_device, :create_other_user_device]
  #
  #   test "mount redirects to session path", %{
  #     admin_conn: conn,
  #     device: _device,
  #     other_device: other_device
  #   } do
  #     path = Routes.device_admin_show_path(conn, :show, other_device)
  #     expected_path = Routes.auth_path(conn, :request)
  #     assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
  #   end
  # end
end
