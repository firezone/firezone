defmodule FzHttpWeb.DeviceLive.Unprivileged.ShowTest do
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
    setup :create_unprivileged_device

    test "includes the device details", %{unprivileged_conn: conn, device: device} do
      path = Routes.device_unprivileged_show_path(conn, :show, device)
      {:ok, _view, html} = live(conn, path)

      assert html =~ device.name
      assert html =~ "Latest Handshake"
    end

    test "deletes the device", %{unprivileged_conn: conn, device: device} do
      path = Routes.device_unprivileged_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#delete-device-button")
      |> render_click()

      {new_path, _flash} = assert_redirect(view)
      assert new_path == Routes.device_unprivileged_index_path(conn, :index)
    end
  end

  # XXX: The events module was removed from the UI in 0.5.0. Re-enable in 0.5.1
  #       when errors are sent on a devices changed notification.
  #
  # describe "authenticated, wireguard interface error" do
  #   setup :create_unprivileged_device

  #   setup do
  #     restore_env(:mock_events_module_errors, true, &on_exit/1)
  #   end

  #   test "deletes the device but displays flash error", %{unprivileged_conn: conn, device: device} do
  #     path = Routes.device_unprivileged_show_path(conn, :show, device)
  #     {:ok, view, _html} = live(conn, path)

  #     view
  #     |> element("#delete-device-button")
  #     |> render_click()

  #     {new_path, flash} = assert_redirect(view)
  #     assert new_path == Routes.device_unprivileged_index_path(conn, :index)

  #     assert flash["error"] ==
  #              """
  #              Device deleted successfully but an error occured applying its configuration to the WireGuard
  #              interface. Please contact your administrator about this error.
  #              """
  #   end
  # end

  describe "authenticated; device management disabled" do
    test "prevents deleting a device; doesn't show button", %{
      unprivileged_user: user,
      unprivileged_conn: conn
    } do
      {:ok, device: device} = create_device(user_id: user.id)
      restore_env(:allow_unprivileged_device_management, false, &on_exit/1)

      path = Routes.device_unprivileged_show_path(conn, :show, device)
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Delete Device"
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
