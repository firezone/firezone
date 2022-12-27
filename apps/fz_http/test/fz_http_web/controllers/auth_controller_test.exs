defmodule FzHttpWeb.AuthControllerTest do
  use FzHttpWeb.ConnCase, async: true

  import Mox

  describe "new" do
    setup [:create_user]

    test "unauthed: loads the sign in form", %{unauthed_conn: conn} do
      expect(OpenIDConnect.Mock, :authorization_uri, fn _, _ -> "https://auth.url" end)

      test_conn = get(conn, ~p"/")

      # Assert that we email, OIDC and Oauth2 buttons provided
      for expected <- [
            "Sign in with email",
            "Sign in with OIDC Google",
            "Sign in with OIDC Okta",
            "Sign in with OIDC Auth0",
            "Sign in with OIDC Azure",
            "Sign in with OIDC Onelogin",
            "Sign in with OIDC Keycloak",
            "Sign in with OIDC Vault",
            "Sign in with SAML"
          ] do
        assert html_response(test_conn, 200) =~ expected
      end
    end

    test "authed as admin: redirects to users page", %{admin_conn: conn} do
      test_conn = get(conn, ~p"/")

      assert redirected_to(test_conn) == ~p"/users"
    end

    test "authed as unprivileged: redirects to user_devices page", %{unprivileged_conn: conn} do
      test_conn = get(conn, ~p"/")

      assert redirected_to(test_conn) == ~p"/user_devices"
    end
  end

  describe "create session" do
    setup [:create_user]

    test "invalid email", %{unauthed_conn: conn} do
      params = %{
        "email" => "invalid@test",
        "password" => "test"
      }

      test_conn = post(conn, ~p"/auth/identity/callback", params)

      assert test_conn.request_path == ~p"/auth/identity/callback"

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "Error signing in: invalid_credentials"
    end

    test "invalid password", %{unauthed_conn: conn, user: user} do
      params = %{
        "email" => user.email,
        "password" => "invalid"
      }

      test_conn = post(conn, ~p"/auth/identity/callback", params)

      assert test_conn.request_path == ~p"/auth/identity/callback"

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "Error signing in: invalid_credentials"
    end

    test "valid params", %{unauthed_conn: conn, user: user} do
      params = %{
        "email" => user.email,
        "password" => "password1234"
      }

      test_conn = post(conn, ~p"/auth/identity/callback", params)

      assert redirected_to(test_conn) == ~p"/users"
      assert current_user(test_conn).id == user.id
    end

    test "prevents signing in when local_auth_disabled", %{unauthed_conn: conn, user: user} do
      params = %{
        "email" => user.email,
        "password" => "password1234"
      }

      FzHttp.Configurations.put!(:local_auth_enabled, false)

      test_conn = post(conn, ~p"/auth/identity/callback", params)
      assert text_response(test_conn, 401) == "Local auth disabled"
    end
  end

  describe "creating session from OpenID Connect" do
    setup :create_user

    @key "fz_oidc_state"
    @state "test"

    @params %{
      "code" => "MyFaketoken",
      "provider" => "google",
      "state" => @state
    }

    setup %{unauthed_conn: conn} = context do
      signed_state =
        Plug.Crypto.sign(
          Application.fetch_env!(:fz_http, FzHttpWeb.Endpoint)[:secret_key_base],
          @key <> "_cookie",
          @state,
          key: Plug.Keys,
          max_age: context[:max_age] || 300
        )

      {:ok, unauthed_conn: put_req_cookie(conn, "fz_oidc_state", signed_state)}
    end

    test "when a user returns with a valid claim", %{unauthed_conn: conn, user: user} do
      expect(OpenIDConnect.Mock, :fetch_tokens, fn _, _ -> {:ok, %{"id_token" => "abc"}} end)

      expect(OpenIDConnect.Mock, :verify, fn _, _ ->
        {:ok, %{"email" => user.email, "sub" => "12345"}}
      end)

      test_conn = get(conn, ~p"/auth/oidc/google/callback", @params)
      assert redirected_to(test_conn) == ~p"/users"
      assert get_session(test_conn, "id_token") == "abc"
    end

    @moduletag :capture_log

    test "when a user returns with an invalid claim", %{unauthed_conn: conn} do
      expect(OpenIDConnect.Mock, :fetch_tokens, fn _, _ -> {:ok, %{}} end)

      expect(OpenIDConnect.Mock, :verify, fn _, _ ->
        {:error, "Invalid token for user!"}
      end)

      test_conn = get(conn, ~p"/auth/oidc/google/callback", @params)

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "OpenIDConnect Error: Invalid token for user!"
    end

    test "when a user returns with an invalid state", %{unauthed_conn: conn} do
      test_conn =
        get(conn, ~p"/auth/oidc/google/callback", %{
          @params
          | "state" => "not_valid"
        })

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "OpenIDConnect Error: Cannot verify state"
    end

    @tag max_age: 0
    test "when a user returns with an expired state", %{unauthed_conn: conn} do
      test_conn = get(conn, ~p"/auth/oidc/google/callback", @params)

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "OpenIDConnect Error: Cannot verify state"
    end
  end

  describe "when deleting a session" do
    setup :create_user

    test "user signed in", %{admin_conn: conn} do
      test_conn = delete(conn, ~p"/sign_out")
      assert redirected_to(test_conn) == ~p"/"
    end

    test "user not signed in", %{unauthed_conn: conn} do
      test_conn = delete(conn, ~p"/sign_out")
      assert redirected_to(test_conn) == ~p"/"
    end
  end

  describe "getting magic link" do
    setup :create_user

    test "redirects to root path", %{unauthed_conn: conn, user: user} do
      test_conn = post(conn, ~p"/auth/magic_link", %{"email" => user.email})

      assert redirected_to(test_conn) == ~p"/"

      assert Phoenix.Flash.get(test_conn.assigns.flash, :info) ==
               "Please check your inbox for the magic link."
    end
  end

  describe "when using magic link" do
    setup :create_user

    alias FzHttp.Repo

    test "user sign_in_token is cleared", %{unauthed_conn: conn, user: user} do
      assert not is_nil(user.sign_in_token)
      assert not is_nil(user.sign_in_token_created_at)

      get(conn, ~p"/auth/magic/#{user.sign_in_token}")

      user = Repo.reload!(user)

      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "user last signed in with magic_link provider", %{unauthed_conn: conn, user: user} do
      get(conn, ~p"/auth/magic/#{user.sign_in_token}")

      user = Repo.reload!(user)

      assert user.last_signed_in_method == "magic_link"
    end

    test "user is signed in", %{unauthed_conn: conn, user: user} do
      test_conn = get(conn, ~p"/auth/magic/#{user.sign_in_token}")

      assert current_user(test_conn).id == user.id
    end

    test "prevents signing in when local_auth_disabled", %{unauthed_conn: conn, user: user} do
      FzHttp.Configurations.put!(:local_auth_enabled, false)

      test_conn = get(conn, ~p"/auth/magic/#{user.sign_in_token}")
      assert text_response(test_conn, 401) == "Local auth disabled"
    end
  end

  describe "oidc signout url" do
    @oidc_end_session_uri "https://end-session.url"
    @params %{
      "id_token_hint" => "abc",
      "post_logout_redirect_uri" => "https://localhost",
      "client_id" => "okta-client-id"
    }

    @tag session: [login_method: "okta", id_token: "abc"]
    test "redirects to oidc end_session_uri", %{admin_conn: conn} do
      # mimics OpenID Connect
      query = URI.encode_query(@params)

      complete_uri =
        @oidc_end_session_uri
        |> URI.merge("?#{query}")
        |> URI.to_string()

      expect(OpenIDConnect.Mock, :end_session_uri, fn _provider, _params -> complete_uri end)

      test_conn = delete(conn, ~p"/sign_out")
      assert redirected_to(test_conn) == complete_uri
    end
  end

  describe "oidc signin url" do
    @oidc_auth_uri "https://auth.url"

    test "redirects to oidc auth uri", %{unauthed_conn: conn} do
      expect(OpenIDConnect.Mock, :authorization_uri, fn provider, _ ->
        case provider do
          :google -> @oidc_auth_uri
        end
      end)

      test_conn = get(conn, ~p"/auth/oidc/google")

      assert redirected_to(test_conn) == @oidc_auth_uri
    end
  end
end
