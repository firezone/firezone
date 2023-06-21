defmodule Web.AuthControllerTest do
  use Web.ConnCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures}

  describe "verify_credentials/2" do
    test "redirects with an error when provider does not exist", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/#{account_id}/sign_in/providers/#{provider_id}/verify_credentials", %{
          "userpass" => %{
            "provider_identifier" => "foo",
            "secret" => "bar"
          }
        })

      assert redirected_to(conn) == "/#{account_id}/sign_in"
      assert flash(conn, :error) == "You can not use this method to sign in."
    end

    test "redirects back to the form when identity does not exist", %{conn: conn} do
      provider = AuthFixtures.create_userpass_provider()

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => "foo",
              "secret" => "bar"
            }
          }
        )

      assert redirected_to(conn) == "/#{provider.account_id}/sign_in"
      assert flash(conn, :error) == "Invalid username or password."
      assert flash(conn, :userpass_provider_identifier) == "foo"
    end

    test "redirects back to the form when credentials are invalid", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_userpass_provider(account: account)

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{
            "password" => "Firezone1234",
            "password_confirmation" => "Firezone1234"
          }
        )

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => "bar"
            }
          }
        )

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert flash(conn, :error) == "Invalid username or password."
      assert flash(conn, :userpass_provider_identifier) == identity.provider_identifier
    end

    test "trims the provider identifier to 160 characters on error redirect", %{conn: conn} do
      provider = AuthFixtures.create_userpass_provider()
      provider_identifier = String.duplicate("a", 161)

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => provider_identifier,
              "secret" => "bar"
            }
          }
        )

      assert redirected_to(conn) == "/#{provider.account_id}/sign_in"
      assert flash(conn, :error) == "Invalid username or password."

      assert flash(conn, :userpass_provider_identifier) ==
               String.slice(provider_identifier, 0, 160)
    end

    test "redirects to the return to path when credentials are valid", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_userpass_provider(account: account)
      password = "Firezone1234"

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      conn =
        conn
        |> put_session(:user_return_to, "/foo/bar")
        |> post(
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => password
            }
          }
        )

      assert redirected_to(conn) == "/foo/bar"
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      conn: conn
    } do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_userpass_provider(account: account)
      password = "Firezone1234"

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      conn =
        conn
        |> post(
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => password
            }
          }
        )

      assert redirected_to(conn) == "/#{account.id}/dashboard"
    end

    test "renews the session when credentials are valid", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_userpass_provider(account: account)
      password = "Firezone1234"

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      conn =
        conn
        |> put_session(:foo, "bar")
        |> put_session(:session_token, "foo")
        |> put_session(:preferred_locale, "en_US")
        |> post(
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => password
            }
          }
        )

      assert %{
               "live_socket_id" => "actors_sessions:" <> socket_id,
               "preferred_locale" => "en_US",
               "session_token" => session_token
             } = conn.private.plug_session

      assert socket_id == identity.actor_id
      assert {:ok, subject} = Domain.Auth.sign_in(session_token, "testing", conn.remote_ip)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == "testing"
      assert subject.identity.last_seen_remote_ip.address == {127, 0, 0, 1}
      assert subject.identity.last_seen_at
    end
  end

  describe "request_magic_link/2" do
    test "sends a login link to the user email", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/request_magic_link",
          %{
            "email" => %{
              "provider_identifier" => identity.provider_identifier
            }
          }
        )

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Sign In Link"

        verify_sign_in_token_path =
          "/#{account.id}/sign_in/providers/#{provider.id}/verify_sign_in_token"

        assert email.text_body =~
                 "#{verify_sign_in_token_path}?identity_id=#{identity.id}&amp;secret="
      end)

      assert redirected_to(conn) == "/#{account.id}/sign_in/providers/email/#{provider.id}"
    end

    test "does not return error if provider is not found", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider_id = Ecto.UUID.generate()

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider_id}/request_magic_link",
          %{"email" => %{"provider_identifier" => "foo"}}
        )

      assert redirected_to(conn) == "/#{account.id}/sign_in/providers/email/#{provider_id}"
    end

    test "does not return error if identity is not found", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider.id}/request_magic_link",
          %{"email" => %{"provider_identifier" => "foo"}}
        )

      assert redirected_to(conn) == "/#{account.id}/sign_in/providers/email/#{provider.id}"
    end
  end

  describe "verify_sign_in_token/2" do
    test "redirects with an error when provider does not exist", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn =
        get(conn, ~p"/#{account_id}/sign_in/providers/#{provider_id}/verify_sign_in_token", %{
          "identity_id" => Ecto.UUID.generate(),
          "secret" => "foo"
        })

      assert redirected_to(conn) == "/#{account_id}/sign_in"
      assert flash(conn, :error) == "You can not use this method to sign in."
    end

    test "redirects back to the form when identity does not exist", %{conn: conn} do
      provider = AuthFixtures.create_email_provider()

      conn =
        get(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => Ecto.UUID.generate(),
            "secret" => "foo"
          }
        )

      assert redirected_to(conn) == "/#{provider.account_id}/sign_in"
      assert flash(conn, :error) == "The sign in link is invalid or expired."
    end

    test "redirects back to the form when credentials are invalid", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      conn =
        get(conn, ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => "bar"
        })

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert flash(conn, :error) == "The sign in link is invalid or expired."
    end

    test "redirects to the return to path when credentials are valid", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      conn =
        conn
        |> put_session(:user_return_to, "/foo/bar")
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => identity.provider_virtual_state.sign_in_token
          }
        )

      assert redirected_to(conn) == "/foo/bar"
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      conn: conn
    } do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      conn =
        get(conn, ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => identity.provider_virtual_state.sign_in_token
        })

      assert redirected_to(conn) == "/#{account.id}/dashboard"
    end

    test "renews the session when credentials are valid", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      conn =
        conn
        |> put_session(:foo, "bar")
        |> put_session(:session_token, "foo")
        |> put_session(:preferred_locale, "en_US")
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => identity.provider_virtual_state.sign_in_token
          }
        )

      assert %{
               "live_socket_id" => "actors_sessions:" <> socket_id,
               "preferred_locale" => "en_US",
               "session_token" => session_token
             } = conn.private.plug_session

      assert socket_id == identity.actor_id
      assert {:ok, subject} = Domain.Auth.sign_in(session_token, "testing", conn.remote_ip)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == "testing"
      assert subject.identity.last_seen_remote_ip.address == {127, 0, 0, 1}
      assert subject.identity.last_seen_at
    end
  end

  describe "redirect_to_idp/2" do
    test "redirects with an error when provider does not exist", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/#{account_id}/sign_in/providers/#{provider_id}/redirect")

      assert redirected_to(conn) == "/#{account_id}/sign_in"
      assert flash(conn, :error) == "You can not use this method to sign in."
    end

    test "redirects to IdP when provider exists", %{conn: conn} do
      account = AccountsFixtures.create_account()

      {provider, _bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      conn = get(conn, ~p"/#{account.id}/sign_in/providers/#{provider.id}/redirect", %{})

      assert to = redirected_to(conn)
      uri = URI.parse(to)
      assert uri.host == "localhost"
      assert uri.path == "/authorize"

      callback_url = url(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback")
      {state, verifier} = conn.cookies["fz_auth_state_#{provider.id}"] |> :erlang.binary_to_term()
      code_challenge = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_challenge(verifier)

      assert URI.decode_query(uri.query) == %{
               "access_type" => "offline",
               "client_id" => provider.adapter_config["client_id"],
               "code_challenge" => code_challenge,
               "code_challenge_method" => "S256",
               "redirect_uri" => callback_url,
               "response_type" => "code",
               "scope" => "openid email profile",
               "state" => state
             }
    end
  end

  describe "handle_idp_callback/2" do
    test "redirects with an error when state is invalid", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn =
        conn
        |> get(~p"/#{account_id}/sign_in/providers/#{provider_id}/handle_callback", %{
          "state" => "foo",
          "code" => "bar"
        })

      assert redirected_to(conn) == "/#{account_id}/sign_in"
      assert flash(conn, :error) == "Your session has expired, please try again."
    end

    test "redirects with an error when provider does not exist", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider_id = Ecto.UUID.generate()
      state = :erlang.term_to_binary({"foo", "bar"})

      conn =
        conn
        |> put_req_cookie("fz_auth_state_#{provider_id}", state)
        |> get(~p"/#{account.id}/sign_in/providers/#{provider_id}/handle_callback", %{
          "state" => "foo",
          "code" => "bar"
        })

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert flash(conn, :error) == "You can not use this method to sign in."
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      conn: conn
    } do
      account = AccountsFixtures.create_account()

      {provider, bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      identity = AuthFixtures.create_identity(account: account, provider: provider)

      {token, _claims} = AuthFixtures.generate_openid_connect_token(provider, identity)
      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})
      AuthFixtures.expect_userinfo(bypass)

      state = :erlang.term_to_binary({"foo", "bar"})

      conn =
        conn
        |> put_req_cookie("fz_auth_state_#{provider.id}", state)
        |> put_session(:foo, "bar")
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => "foo",
          "code" => "MyFakeCode"
        })

      assert redirected_to(conn) == "/#{account.id}/dashboard"

      assert %{
               "live_socket_id" => "actors_sessions:" <> socket_id,
               "preferred_locale" => "en_US",
               "session_token" => session_token
             } = conn.private.plug_session

      assert socket_id == identity.actor_id
      assert {:ok, subject} = Domain.Auth.sign_in(session_token, "testing", conn.remote_ip)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == "testing"
      assert subject.identity.last_seen_remote_ip.address == {127, 0, 0, 1}
      assert subject.identity.last_seen_at
    end
  end

  describe "sign_out/2" do
    test "redirects to the sign in page and renews the session", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      conn =
        conn
        |> authorize_conn(identity)
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert conn.private.plug_session == %{"preferred_locale" => "en_US"}
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      live_socket_id = "actors_sessions:#{identity.actor_id}"
      Web.Endpoint.subscribe(live_socket_id)

      conn =
        conn
        |> put_session(:live_socket_id, live_socket_id)
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) == "/#{account.id}/sign_in"

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if user is already logged out", %{conn: conn} do
      account = AccountsFixtures.create_account()

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert conn.private.plug_session == %{"preferred_locale" => "en_US"}
    end
  end
end
