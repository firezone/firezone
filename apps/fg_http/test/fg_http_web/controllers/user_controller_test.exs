defmodule FgHttpWeb.UserControllerTest do
  use FgHttpWeb.ConnCase, async: true

  describe "when user signed in" do
    test "deletes the user", %{authed_conn: conn} do
      test_conn = delete(conn, Routes.user_path(conn, :delete))

      assert redirected_to(test_conn) == Routes.root_index_path(test_conn, :index)
    end
  end

  describe "when user not signed in" do
    test "redirects to 403", %{unauthed_conn: conn} do
      test_conn = delete(conn, Routes.user_path(conn, :delete))

      assert text_response(test_conn, 403)
    end
  end
end
