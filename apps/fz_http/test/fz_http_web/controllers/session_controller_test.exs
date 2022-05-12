defmodule FzHttpWeb.AuthControllerTest do
  use FzHttpWeb.ConnCase, async: true

  describe "new" do
    setup [:create_user]

    test "unauthed: loads the sign in form", %{unauthed_conn: conn} do
      test_conn = get(conn, Routes.root_path(conn, :index))

      assert html_response(test_conn, 200) =~ "Sign In"
    end

    test "authed as admin: redirects to users page", %{admin_conn: conn} do
      test_conn = get(conn, Routes.root_path(conn, :index))

      assert redirected_to(test_conn) == Routes.user_index_path(test_conn, :index)
    end

    test "authed as unprivileged: redirects to user_devices page", %{unprivileged_conn: conn} do
      test_conn = get(conn, Routes.root_path(conn, :index))

      assert redirected_to(test_conn) == Routes.device_unprivileged_index_path(test_conn, :index)
    end
  end

  describe "create session" do
    setup [:create_user]

    test "invalid email", %{unauthed_conn: conn} do
      params = %{
        "email" => "invalid@test",
        "password" => "test"
      }

      test_conn = post(conn, Routes.auth_path(conn, :callback, :identity), params)

      assert test_conn.request_path == Routes.auth_path(test_conn, :callback, :identity)
      assert get_flash(test_conn, :error) == "Error signing in: invalid_credentials"
    end

    test "invalid password", %{unauthed_conn: conn, user: user} do
      params = %{
        "email" => user.email,
        "password" => "invalid"
      }

      test_conn = post(conn, Routes.auth_path(conn, :callback, :identity), params)

      assert test_conn.request_path == Routes.auth_path(test_conn, :callback, :identity)
      assert get_flash(test_conn, :error) == "Error signing in: invalid_credentials"
    end

    test "valid params", %{unauthed_conn: conn, user: user} do
      params = %{
        "email" => user.email,
        "password" => "password1234"
      }

      test_conn = post(conn, Routes.auth_path(conn, :callback, :identity), params)

      assert redirected_to(test_conn) == Routes.user_index_path(test_conn, :index)
      assert current_user(test_conn).id == user.id
    end
  end

  describe "when deleting a session" do
    setup :create_user

    test "user signed in", %{admin_conn: conn} do
      test_conn = delete(conn, Routes.auth_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.root_path(test_conn, :index)
    end

    test "user not signed in", %{unauthed_conn: conn} do
      test_conn = delete(conn, Routes.auth_path(conn, :delete))
      assert redirected_to(test_conn) == Routes.root_path(test_conn, :index)
    end
  end

  describe "getting magic link" do
    setup :create_user

    import Swoosh.TestAssertions

    test "sends a magic link in email", %{unauthed_conn: conn, user: user} do
      post(conn, Routes.auth_path(conn, :magic_link), %{"email" => user.email})

      Process.sleep(100)
      assert_email_sent(subject: "Firezone Magic Link", to: [{"", user.email}])
    end
  end

  describe "when using magic link" do
    setup :create_user

    alias FzHttp.Repo

    test "user sign_in_token is cleared", %{unauthed_conn: conn, user: user} do
      assert not is_nil(user.sign_in_token)
      assert not is_nil(user.sign_in_token_created_at)

      get(conn, Routes.auth_path(conn, :magic_sign_in, user.sign_in_token))

      user = Repo.reload!(user)

      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "user last signed in with magic_link provider", %{unauthed_conn: conn, user: user} do
      get(conn, Routes.auth_path(conn, :magic_sign_in, user.sign_in_token))

      user = Repo.reload!(user)

      assert user.last_signed_in_method == "magic_link"
    end

    test "user is signed in", %{unauthed_conn: conn, user: user} do
      test_conn = get(conn, Routes.auth_path(conn, :magic_sign_in, user.sign_in_token))

      assert current_user(test_conn).id == user.id
    end
  end
end
