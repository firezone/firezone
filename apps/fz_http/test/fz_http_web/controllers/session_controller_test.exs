defmodule FzHttpWeb.AuthControllerTest do
  use FzHttpWeb.ConnCase, async: true

  import Mox

  describe "new" do
    setup [:create_user]

    test "unauthed: loads the sign in form", %{unauthed_conn: conn} do
      expect(OpenIDConnect.Mock, :authorization_uri, fn _ -> "https://auth.url" end)
      test_conn = get(conn, Routes.root_path(conn, :index))

      # Assert that we email, OIDC and Oauth2 buttons provided
      for expected <- [
            "Sign in with email",
            "Sign in with OIDC Google",
            "Sign in with Google",
            "Sign in with Okta"
          ] do
        assert html_response(test_conn, 200) =~ expected
      end
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

  describe "creating session from OpenID Connect" do
    setup [:create_user]

    test "when a user returns with a valid claim", %{unauthed_conn: conn, user: user} do
      expect(OpenIDConnect.Mock, :fetch_tokens, fn _, _ -> {:ok, %{"id_token" => "abc"}} end)

      expect(OpenIDConnect.Mock, :verify, fn _, _ ->
        {:ok, %{"email" => user.email, "sub" => "12345"}}
      end)

      params = %{
        "code" => "MyFaketoken",
        "provider" => "google"
      }

      test_conn = get(conn, Routes.auth_oidc_path(conn, :callback, "google"), params)

      assert redirected_to(test_conn) == Routes.user_index_path(test_conn, :index)
    end

    @moduletag :capture_log
    test "when a user returns with an invalid claim", %{unauthed_conn: conn} do
      expect(OpenIDConnect.Mock, :fetch_tokens, fn _, _ -> {:ok, %{}} end)

      expect(OpenIDConnect.Mock, :verify, fn _, _ ->
        {:error, "Invalid token for user!"}
      end)

      params = %{
        "code" => "MyFaketoken",
        "provider" => "google"
      }

      test_conn = get(conn, Routes.auth_oidc_path(conn, :callback, "google"), params)
      assert get_flash(test_conn, :error) == "OpenIDConnect Error: Invalid token for user!"
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
end
