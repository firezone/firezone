defmodule FgHttpWeb.SessionControllerTest do
  use FgHttpWeb.ConnCase, async: true

  describe "signing in" do
    setup [:create_user]

    test "token invalid; session not set", %{unauthed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.session_path(conn, :create, "invalid"))

      assert redirected_to(test_conn) == Routes.session_new_path(test_conn, :new)
      assert get_flash(test_conn, :error) == "Token invalid."
    end

    test "token valid; sets session", %{unauthed_conn: conn, user: user} do
      test_conn = get(conn, Routes.session_path(conn, :create, user.sign_in_token))

      assert redirected_to(test_conn) == Routes.root_index_path(test_conn, :index)
      assert get_session(test_conn, :user_id) == user.id
    end
  end

  describe "when deleting a session" do
    setup [:create_user]

    test "user signed in", %{authed_conn: conn, user: _user} do
      test_conn = post(conn, Routes.session_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.root_index_path(test_conn, :index)
    end

    test "user not signed in", %{unauthed_conn: conn, user: _user} do
      test_conn = post(conn, Routes.session_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.root_index_path(test_conn, :index)
    end
  end
end
