defmodule FzHttpWeb.SessionControllerTest do
  use FzHttpWeb.ConnCase, async: true

  describe "new" do
    setup [:create_user]

    test "unauthed: loads the sign in form", %{unauthed_conn: conn, user: _user} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert html_response(test_conn, 200) =~ "Sign In"
    end

    test "authed as admin: redirects to users page", %{admin_conn: conn, user: _user} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert redirected_to(test_conn) == Routes.user_index_path(test_conn, :index)
    end

    test "authed as unprivileged: redirects to user_devices page", %{unprivileged_conn: conn} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert redirected_to(test_conn) == Routes.device_unprivileged_index_path(test_conn, :index)
    end
  end

  describe "create session" do
    setup [:create_user]

    test "invalid email", %{unauthed_conn: conn, user: _user} do
      params = %{
        "user" => %{
          "email" => "invalid@test",
          "password" => "test"
        }
      }

      test_conn = post(conn, Routes.session_path(conn, :create), params)

      assert test_conn.request_path == Routes.session_path(test_conn, :new)
      assert get_flash(test_conn, :error) == "Incorrect email or password."
    end

    test "invalid password", %{unauthed_conn: conn, user: user} do
      params = %{
        "user" => %{
          "email" => user.email,
          "password" => "invalid"
        }
      }

      test_conn = post(conn, Routes.session_path(conn, :create), params)

      assert test_conn.request_path == Routes.session_path(test_conn, :new)
      assert get_flash(test_conn, :error) == "Incorrect email or password."
    end

    test "valid params", %{unauthed_conn: conn, user: user} do
      params = %{
        "user" => %{
          "email" => user.email,
          "password" => "password1234"
        }
      }

      test_conn = post(conn, Routes.session_path(conn, :create), params)

      assert redirected_to(test_conn) == Routes.user_index_path(test_conn, :index)
      assert current_user(test_conn).id == user.id
    end
  end

  describe "when deleting a session" do
    setup :create_user

    test "user signed in", %{admin_conn: conn, user: _user} do
      test_conn = delete(conn, Routes.session_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end

    test "user not signed in", %{unauthed_conn: conn, user: _user} do
      test_conn = delete(conn, Routes.session_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end
end
