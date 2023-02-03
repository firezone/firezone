defmodule FzHttpWeb.AuthControllerTest do
  use FzHttpWeb.ConnCase, async: true
  alias FzHttp.ConfigurationsFixtures
  alias FzHttp.Repo

  setup do
    {bypass, _openid_connect_providers_attrs} =
      ConfigurationsFixtures.start_openid_providers([
        "google",
        "okta",
        "auth0",
        "azure",
        "onelogin",
        "keycloak",
        "vault"
      ])

    FzHttp.Configurations.put!(
      :saml_identity_providers,
      [FzHttp.SAMLIdentityProviderFixtures.saml_attrs() |> Map.put("label", "SAML")]
    )

    %{bypass: bypass}
  end

  describe "new" do
    setup [:create_user]

    test "unauthed: loads the sign in form", %{unauthed_conn: conn} do
      test_conn = get(conn, ~p"/")

      # Assert that we have email, OIDC and Oauth2 buttons provided
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

    test "GET /auth/identity/callback redirects to /", %{unauthed_conn: conn} do
      assert redirected_to(get(conn, ~p"/auth/identity/callback")) == ~p"/"
    end

    test "GET /auth/identity omits forgot password link when local_auth disabled", %{
      unauthed_conn: conn
    } do
      FzHttp.Configurations.put!(:local_auth_enabled, false)
      test_conn = get(conn, ~p"/auth/identity")

      assert text_response(test_conn, 404) == "Local auth disabled"
    end

    test "when local_auth is disabled responds with 404", %{unauthed_conn: conn} do
      FzHttp.Configurations.put!(:local_auth_enabled, false)
      test_conn = post(conn, ~p"/auth/identity/callback", %{})

      assert text_response(test_conn, 404) == "Local auth disabled"
    end

    test "invalid email", %{unauthed_conn: conn} do
      params = %{
        "email" => "invalid@test",
        "password" => "test"
      }

      test_conn = post(conn, ~p"/auth/identity/callback", params)

      assert test_conn.request_path == ~p"/auth/identity/callback"

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "Error signing in: user credentials are invalid or user does not exist"
    end

    test "invalid password", %{unauthed_conn: conn, user: user} do
      params = %{
        "email" => user.email,
        "password" => "invalid"
      }

      test_conn = post(conn, ~p"/auth/identity/callback", params)

      assert test_conn.request_path == ~p"/auth/identity/callback"

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "Error signing in: user credentials are invalid or user does not exist"
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
      assert text_response(test_conn, 404) == "Local auth disabled"
    end
  end

  describe "GET /auth/reset_password" do
    test "protects route when local_auth is disabled", %{unauthed_conn: conn} do
      FzHttp.Configurations.put!(:local_auth_enabled, false)
      test_conn = get(conn, ~p"/auth/reset_password")

      assert text_response(test_conn, 404) == "Local auth disabled"
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

    test "when a user returns with a valid claim", %{
      unauthed_conn: conn,
      user: user,
      bypass: bypass
    } do
      jwk = ConfigurationsFixtures.jwks_attrs()

      claims = %{"email" => user.email, "sub" => user.id}

      {_alg, token} =
        jwk
        |> JOSE.JWK.from()
        |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      ConfigurationsFixtures.expect_refresh_token(bypass, %{"id_token" => token})

      test_conn = get(conn, ~p"/auth/oidc/google/callback", @params)
      assert redirected_to(test_conn) == ~p"/users"

      assert get_session(test_conn, "id_token")
    end

    test "when a user returns with an invalid claim", %{unauthed_conn: conn, bypass: bypass} do
      jwk = ConfigurationsFixtures.jwks_attrs()

      claims = %{"email" => "foo@example.com", "sub" => Ecto.UUID.generate()}

      {_alg, token} =
        jwk
        |> JOSE.JWK.from()
        |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256"})
        |> JOSE.JWS.compact()

      ConfigurationsFixtures.expect_refresh_token(bypass, %{"id_token" => token})

      test_conn = get(conn, ~p"/auth/oidc/google/callback", @params)

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "Error signing in: user not found and auto_create_users disabled"
    end

    test "when a user returns with an invalid state", %{unauthed_conn: conn} do
      test_conn =
        get(conn, ~p"/auth/oidc/google/callback", %{
          @params
          | "state" => "not_valid"
        })

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "An OpenIDConnect error occurred. Details: \"Cannot verify state\""
    end

    @tag max_age: 0
    test "when a user returns with an expired state", %{unauthed_conn: conn} do
      test_conn = get(conn, ~p"/auth/oidc/google/callback", @params)

      assert Phoenix.Flash.get(test_conn.assigns.flash, :error) ==
               "An OpenIDConnect error occurred. Details: \"Cannot verify state\""
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
      refute user.sign_in_token

      test_conn = post(conn, ~p"/auth/magic_link", %{"email" => user.email})

      assert redirected_to(test_conn) == ~p"/"

      assert Phoenix.Flash.get(test_conn.assigns.flash, :info) ==
               "Please check your inbox for the magic link."

      user = Repo.get(FzHttp.Users.User, user.id)
      assert user.sign_in_token_hash

      assert_receive {:email, email}

      assert email.subject == "Firezone Magic Link"
      assert email.to == [{"", user.email}]
      assert email.text_body =~ "/auth/magic/#{user.id}/"

      token = String.split(email.assigns.link, "/") |> List.last()

      assert {:ok, _user} = FzHttp.Users.consume_sign_in_token(user, token)
    end
  end

  describe "when using magic link" do
    setup :create_user

    setup context do
      {:ok, user} = FzHttp.Users.request_sign_in_token(context.user)
      Map.put(context, :user, user)
    end

    test "user sign_in_token is cleared", %{unauthed_conn: conn, user: user} do
      assert not is_nil(user.sign_in_token)
      assert not is_nil(user.sign_in_token_created_at)

      get(conn, ~p"/auth/magic/#{user.id}/#{user.sign_in_token}")

      user = Repo.reload!(user)

      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "user last signed in with magic_link provider", %{unauthed_conn: conn, user: user} do
      get(conn, ~p"/auth/magic/#{user.id}/#{user.sign_in_token}")

      user = Repo.reload!(user)

      assert user.last_signed_in_method == "magic_link"
    end

    test "user is signed in", %{unauthed_conn: conn, user: user} do
      test_conn = get(conn, ~p"/auth/magic/#{user.id}/#{user.sign_in_token}")

      assert current_user(test_conn).id == user.id
    end

    test "prevents signing in when local_auth_disabled", %{unauthed_conn: conn, user: user} do
      FzHttp.Configurations.put!(:local_auth_enabled, false)

      test_conn = get(conn, ~p"/auth/magic/#{user.id}/#{user.sign_in_token}")
      assert text_response(test_conn, 404) == "Local auth disabled"
    end
  end

  describe "oidc signout url" do
    @tag session: [login_method: "okta", id_token: "abc"]
    test "redirects to oidc end_session_uri", %{admin_conn: conn} do
      query =
        URI.encode_query(%{
          "id_token_hint" => "abc",
          "post_logout_redirect_uri" => FzHttp.Config.fetch_env!(:fz_http, :external_url),
          "client_id" => "okta-client-id"
        })

      complete_uri =
        "https://example.com"
        |> URI.merge("?#{query}")
        |> URI.to_string()

      test_conn = delete(conn, ~p"/sign_out")
      assert redirected_to(test_conn) == complete_uri
    end
  end

  describe "oidc signin url" do
    test "redirects to oidc auth uri", %{unauthed_conn: conn, bypass: bypass} do
      test_conn = get(conn, ~p"/auth/oidc/google")

      bypass_url = "http://localhost:#{bypass.port}/authorize"
      assert String.starts_with?(redirected_to(test_conn), bypass_url)
    end
  end
end
