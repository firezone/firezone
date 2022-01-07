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
end
