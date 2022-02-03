defmodule FzHttpWeb.DeviceControllerTest do
  use FzHttpWeb.ConnCase, async: true

  describe "index" do
    setup [:create_user]

    test "authenticated loads device live view", %{authed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.root_path(conn, :index))

      assert redirected_to(test_conn) == Routes.device_index_path(test_conn, :index)
    end

    test "unauthenticated redirects to sign in", %{unauthed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.root_path(conn, :index))

      assert redirected_to(test_conn) == Routes.session_path(conn, :new)
    end
  end

  describe "config" do
    setup :create_device_with_config_token

    test "config can be shown", %{device: device, unauthed_conn: conn} do
      test_conn = get(conn, Routes.device_path(conn, :config, device.config_token))

      assert html_response(test_conn, 200) =~ "Download Configuration"
      assert html_response(test_conn, 200) =~ device.config_token
    end
  end

  describe "download_shared_config" do
    setup :create_device_with_config_token

    test "config can be downloaded", %{device: device, unauthed_conn: conn} do
      test_conn =
        get(
          conn,
          Routes.device_path(conn, :download_shared_config, device.config_token)
        )

      assert test_conn.resp_body == FzHttp.Devices.as_config(device)
    end
  end
end
