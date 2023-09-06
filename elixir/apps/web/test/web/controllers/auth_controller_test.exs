defmodule Web.AuthControllerTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)
    %{}
  end

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
      provider = Fixtures.Auth.create_userpass_provider()

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
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
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
      provider = Fixtures.Auth.create_userpass_provider()
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
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      password = "Firezone1234"

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity =
        Fixtures.Auth.create_identity(
          actor: actor,
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

      assert conn.assigns.flash == %{}
      assert redirected_to(conn) == "/foo/bar"
      assert is_nil(get_session(conn, :user_return_to))
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      password = "Firezone1234"

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
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

      assert redirected_to(conn) == "/#{account.slug}/dashboard"
    end

    test "renews the session when credentials are valid", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      password = "Firezone1234"

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
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

    test "redirects to the platform link when credentials are valid for account users", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      password = "Firezone1234"

      actor =
        Fixtures.Actors.create_actor(
          type: :account_user,
          account: account,
          provider: provider
        )

      identity =
        Fixtures.Auth.create_identity(
          actor: actor,
          account: account,
          provider: provider,
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      csrf_token = Ecto.UUID.generate()

      conn =
        conn
        |> post(
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => password
            },
            "client_platform" => "android",
            "client_csrf_token" => csrf_token
          }
        )

      assert conn.assigns.flash == %{}

      assert is_nil(get_session(conn, :user_return_to))

      assert redirected_to = redirected_to(conn)
      assert redirected_to_uri = URI.parse(redirected_to)
      assert redirected_to_uri.scheme == "https"
      assert redirected_to_uri.host == "app.firez.one"
      assert redirected_to_uri.path == "/handle_client_auth_callback"

      assert %{
               "client_auth_token" => _token,
               "client_csrf_token" => ^csrf_token
             } = URI.decode_query(redirected_to_uri.query)
    end

    test "redirects account users to app install page when mobile platform is invalid", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      password = "Firezone1234"

      actor =
        Fixtures.Actors.create_actor(
          type: :account_user,
          account: account,
          provider: provider
        )

      identity =
        Fixtures.Auth.create_identity(
          actor: actor,
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
            },
            "client_platform" => "platform"
          }
        )

      assert conn.assigns.flash == %{
               "info" => "Please use a client application to access Firezone."
             }

      assert redirected_to(conn) == ~p"/#{account.id}/"
      assert is_nil(get_session(conn, :user_return_to))
    end
  end

  describe "request_magic_link/2" do
    test "sends a login link to the user email", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

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

        assert email.text_body =~ "#{verify_sign_in_token_path}"
        assert email.text_body =~ "identity_id=#{identity.id}"
        assert email.text_body =~ "secret="
      end)

      assert redirected_to(conn) ==
               "/#{account.id}/sign_in/providers/email/#{provider.id}?" <>
                 "provider_identifier=#{URI.encode_www_form(identity.provider_identifier)}"
    end

    test "persists client platform name", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/request_magic_link",
          %{
            "email" => %{
              "provider_identifier" => identity.provider_identifier
            },
            "client_platform" => "platform"
          }
        )

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Sign In Link"
        assert email.text_body =~ "Please copy the code and paste it into"
      end)

      assert url = redirected_to(conn)
      uri = URI.parse(url)
      assert uri.path == "/#{account.id}/sign_in/providers/email/#{provider.id}"

      assert URI.decode_query(uri.query) == %{
               "client_platform" => "platform",
               "provider_identifier" => identity.provider_identifier
             }

      assert get_session(conn, :client_platform) == "platform"
    end

    test "does not return error if provider is not found", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider_id = Ecto.UUID.generate()

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider_id}/request_magic_link",
          %{"email" => %{"provider_identifier" => "foo"}}
        )

      assert redirected_to(conn) ==
               "/#{account.id}/sign_in/providers/email/#{provider_id}?" <>
                 "provider_identifier=foo"
    end

    test "does not return error if identity is not found", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider.id}/request_magic_link",
          %{"email" => %{"provider_identifier" => "foo"}}
        )

      assert redirected_to(conn) ==
               "/#{account.id}/sign_in/providers/email/#{provider.id}?provider_identifier=foo"
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
      provider = Fixtures.Auth.create_email_provider()

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
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        get(conn, ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => "bar"
        })

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert flash(conn, :error) == "The sign in link is invalid or expired."
    end

    test "redirects back to the form when browser token is invalid", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {email_token, _browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:browser_csrf_token, "foo")
        |> put_session(:user_return_to, "/foo/bar")
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => email_token
          }
        )

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert flash(conn, :error) == "The sign in link is invalid or expired."
    end

    test "redirects back to the form when browser token is not set", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {email_token, _browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:user_return_to, "/foo/bar")
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => email_token
          }
        )

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert flash(conn, :error) == "The sign in link is invalid or expired."
    end

    test "redirects to the return to path when credentials are valid", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {email_token, browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:browser_csrf_token, browser_token)
        |> put_session(:user_return_to, "/foo/bar")
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => email_token
          }
        )

      assert conn.assigns.flash == %{}
      assert redirected_to(conn) == "/foo/bar"
      assert is_nil(get_session(conn, :user_return_to))
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider
        )

      {email_token, browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:browser_csrf_token, browser_token)
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => email_token
        })

      assert redirected_to(conn) == "/#{account.slug}/dashboard"
    end

    test "redirects to the platform link when credentials are valid for account users", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_user],
          account: account,
          provider: provider
        )

      {email_token, browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:browser_csrf_token, browser_token)
        |> put_session(:client_platform, "apple")
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => email_token
        })

      assert conn.assigns.flash == %{}
      assert is_nil(get_session(conn, :client_platform))

      assert redirected_to = conn |> redirected_to() |> URI.parse()
      assert redirected_to.scheme == "firezone"
      assert redirected_to.host == "handle_client_auth_callback"

      assert query_params = URI.decode_query(redirected_to.query)
      assert query_params["actor_name"] == Repo.preload(identity, :actor).actor.name
      assert not is_nil(query_params["client_auth_token"])
      assert query_params["identity_provider_identifier"] == identity.provider_identifier
    end

    test "platform link can be stored in URL links when session cookie is not available", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_user],
          account: account,
          provider: provider
        )

      {email_token, browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:browser_csrf_token, browser_token)
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => email_token,
          "client_platform" => "apple"
        })

      assert conn.assigns.flash == %{}
      assert is_nil(get_session(conn, :client_platform))

      assert redirected_to = conn |> redirected_to() |> URI.parse()
      assert redirected_to.scheme == "firezone"
      assert redirected_to.host == "handle_client_auth_callback"

      assert query_params = URI.decode_query(redirected_to.query)
      assert query_params["actor_name"] == Repo.preload(identity, :actor).actor.name
      assert not is_nil(query_params["client_auth_token"])
      assert query_params["identity_provider_identifier"] == identity.provider_identifier
    end

    test "renews the session when credentials are valid", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {email_token, browser_token} = split_token(identity)

      conn =
        conn
        |> put_session(:foo, "bar")
        |> put_session(:session_token, "foo")
        |> put_session(:preferred_locale, "en_US")
        |> put_session(:browser_csrf_token, browser_token)
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => email_token
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
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

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

    test "persists client platform name", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      conn =
        get(conn, ~p"/#{account.id}/sign_in/providers/#{provider.id}/redirect", %{
          "client_platform" => "platform"
        })

      assert get_session(conn, :client_platform) == "platform"
    end
  end

  describe "handle_idp_callback/2" do
    setup context do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      conn = get(context.conn, ~p"/#{account.id}/sign_in/providers/#{provider.id}/redirect", %{})

      %{
        account: account,
        provider: provider,
        bypass: bypass,
        redirected_conn: conn
      }
    end

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

    test "redirects with an error when state cookie does not exist", %{
      account: account,
      provider: provider,
      redirected_conn: redirected_conn,
      conn: conn
    } do
      cookie_key = "fz_auth_state_#{provider.id}"
      redirected_conn = fetch_cookies(redirected_conn)
      {state, _verifier} = redirected_conn.cookies[cookie_key] |> :erlang.binary_to_term([:safe])
      %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

      conn =
        conn
        |> put_req_cookie(cookie_key, signed_state)
        |> get(~p"/#{account}/sign_in/providers/#{Ecto.UUID.generate()}/handle_callback", %{
          "state" => state,
          "code" => "bar"
        })

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      assert flash(conn, :error) == "Your session has expired, please try again."
    end

    test "redirects with an error when provider io disabled", %{
      account: account,
      provider: provider,
      redirected_conn: redirected_conn,
      conn: conn
    } do
      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider
        )

      subject = Fixtures.Auth.create_subject(identity: identity)
      Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _provider} = Domain.Auth.disable_provider(provider, subject)

      cookie_key = "fz_auth_state_#{provider.id}"
      redirected_conn = fetch_cookies(redirected_conn)
      {state, _verifier} = redirected_conn.cookies[cookie_key] |> :erlang.binary_to_term([:safe])
      %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

      conn =
        conn
        |> put_req_cookie(cookie_key, signed_state)
        |> get(~p"/#{account}/sign_in/providers/#{provider}/handle_callback", %{
          "state" => state,
          "code" => "bar"
        })

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      assert flash(conn, :error) == "You can not use this method to sign in."
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      account: account,
      provider: provider,
      bypass: bypass,
      conn: conn,
      redirected_conn: redirected_conn
    } do
      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider
        )

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      cookie_key = "fz_auth_state_#{provider.id}"
      redirected_conn = fetch_cookies(redirected_conn)
      {state, _verifier} = redirected_conn.cookies[cookie_key] |> :erlang.binary_to_term([:safe])
      %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

      conn =
        conn
        |> put_req_cookie(cookie_key, signed_state)
        |> put_session(:foo, "bar")
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      assert redirected_to(conn) == "/#{account.slug}/dashboard"

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

    test "redirects to the platform link when credentials are valid for account users", %{
      account: account,
      provider: provider,
      bypass: bypass,
      conn: conn,
      redirected_conn: redirected_conn
    } do
      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_user],
          account: account,
          provider: provider
        )

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      cookie_key = "fz_auth_state_#{provider.id}"
      redirected_conn = fetch_cookies(redirected_conn)
      {state, _verifier} = redirected_conn.cookies[cookie_key] |> :erlang.binary_to_term([:safe])
      %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

      conn =
        conn
        |> put_req_cookie(cookie_key, signed_state)
        |> put_session(:foo, "bar")
        |> put_session(:preferred_locale, "en_US")
        |> put_session(:client_platform, "apple")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      assert conn.assigns.flash == %{}
      assert is_nil(get_session(conn, :client_platform))

      assert redirected_to = conn |> redirected_to() |> URI.parse()
      assert redirected_to.scheme == "firezone"
      assert redirected_to.host == "handle_client_auth_callback"

      assert query_params = URI.decode_query(redirected_to.query)
      assert query_params["actor_name"] == Repo.preload(identity, :actor).actor.name
      assert not is_nil(query_params["client_auth_token"])
      assert query_params["identity_provider_identifier"] == identity.provider_identifier
    end
  end

  describe "sign_out/2" do
    test "redirects to the sign in page and renews the session", %{conn: conn} do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        conn
        |> authorize_conn(identity)
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert conn.private.plug_session == %{"preferred_locale" => "en_US"}
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

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
      account = Fixtures.Accounts.create_account()

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) == "/#{account.id}/sign_in"
      assert conn.private.plug_session == %{"preferred_locale" => "en_US"}
    end
  end

  defp split_token(identity, size \\ 5) do
    <<email_secret::binary-size(size), browser_secret::binary>> =
      identity.provider_virtual_state.sign_in_token

    {email_secret, browser_secret}
  end
end
