defmodule FzHttpWeb.SessionControllerTest do
  use FzHttpWeb.ConnCase, async: true

  describe "new" do
    setup [:create_user]

    test "unauthed: loads the sign in form", %{unauthed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert html_response(test_conn, 200) =~ "Sign In"
    end

    test "authed: redirects to devices page", %{authed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert redirected_to(test_conn) == Routes.device_index_path(test_conn, :index)
    end
  end

  describe "create session" do
    setup [:create_user]

    test "invalid email", %{unauthed_conn: conn, user: _user} do
      params = %{
        "session" => %{
          "email" => "invalid@test",
          "password" => "test"
        }
      }

      test_conn = post(conn, Routes.session_path(conn, :create), params)

      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
      assert get_flash(test_conn, :error) =~ "Email not found."
    end

    test "invalid password", %{unauthed_conn: conn, user: user} do
      params = %{
        "session" => %{
          "email" => user.email,
          "password" => "invalid"
        }
      }

      test_conn = post(conn, Routes.session_path(conn, :create), params)

      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)

      assert get_flash(test_conn, :error) =~
               "Error signing in. Ensure email and password are correct."
    end

    test "valid params", %{unauthed_conn: conn, user: user} do
      params = %{
        "session" => %{
          "email" => user.email,
          "password" => "password1234"
        }
      }

      test_conn = post(conn, Routes.session_path(conn, :create), params)

      assert redirected_to(test_conn) == Routes.root_path(test_conn, :index)
      assert get_session(test_conn, :user_id) == user.id
    end

    test "token invalid; session not set", %{unauthed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.session_path(conn, :create, "invalid"))

      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
      assert get_flash(test_conn, :error) == "Token invalid."
    end

    test "token valid; sets session", %{unauthed_conn: conn, user: user} do
      test_conn = get(conn, Routes.session_path(conn, :create, user.sign_in_token))

      assert redirected_to(test_conn) == Routes.device_index_path(test_conn, :index)
      assert get_session(test_conn, :user_id) == user.id
    end
  end

  describe "when deleting a session" do
    setup :create_user

    test "user signed in", %{authed_conn: conn, user: _user} do
      test_conn = delete(conn, Routes.session_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end

    test "user not signed in", %{unauthed_conn: conn, user: _user} do
      test_conn = delete(conn, Routes.session_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end
end
