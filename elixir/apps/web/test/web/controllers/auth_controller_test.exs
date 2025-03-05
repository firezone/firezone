defmodule Web.AuthControllerTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    %{}
  end

  describe "verify_credentials/2" do
    test "redirects to account root when required params aren't provided", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      params = %{"foo" => "bar"}
      conn = post(conn, ~p"/#{account}/sign_in/providers/#{provider}/verify_credentials", params)

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) =~ "Invalid request."
    end

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

      assert redirected_to(conn) == "/#{account_id}"
      assert flash(conn, :error) == "You may not use this method to sign in."
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

      assert redirected_to(conn) == "/#{provider.account_id}"
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

      assert redirected_to(conn) == "/#{account.id}"
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

      assert redirected_to(conn) == "/#{provider.account_id}"
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
        |> post(
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "redirect_to" => ~p"/#{account}/relay_groups",
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => password
            }
          }
        )

      assert conn.assigns.flash == %{}
      assert redirected_to(conn) == ~p"/#{account}/relay_groups"
      assert is_nil(get_session(conn, :user_return_to))
    end

    test "redirects to the actors index when credentials are valid and return path is empty", %{
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
          ~p"/#{account}/sign_in/providers/#{provider.id}/verify_credentials",
          %{
            "userpass" => %{
              "provider_identifier" => identity.provider_identifier,
              "secret" => password
            }
          }
        )

      assert redirected_to(conn) == ~p"/#{account.slug}/sites"
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

      session = {:browser, "x", "foo"}

      conn =
        conn
        |> put_session(:foo, "bar")
        |> put_session(:sessions, [session])
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
               "preferred_locale" => "en_US",
               "sessions" => [
                 ^session,
                 {:browser, _account_id, session_token}
               ]
             } = conn.private.plug_session

      context = %Domain.Auth.Context{
        type: :browser,
        remote_ip: conn.remote_ip,
        user_agent: "testing",
        remote_ip_location_region: "Mexico",
        remote_ip_location_city: "Merida",
        remote_ip_location_lat: 37.7749,
        remote_ip_location_lon: -120.4194
      }

      assert {:ok, subject} = Domain.Auth.authenticate(session_token, context)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == "testing"
      assert subject.identity.last_seen_remote_ip.address == {127, 0, 0, 1}
      assert subject.identity.last_seen_remote_ip_location_region == "Mexico"
      assert subject.identity.last_seen_remote_ip_location_city == "Merida"
      assert subject.identity.last_seen_remote_ip_location_lat == 37.7749
      assert subject.identity.last_seen_remote_ip_location_lon == -120.4194
      assert subject.identity.last_seen_at
    end

    test "redirects to the apple platform URI when credentials are valid for account users", %{
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
            "as" => "client",
            "state" => "STATE",
            "nonce" => "NONCE"
          }
        )

      assert conn.assigns.flash == %{}

      assert response = response(conn, 200)
      assert response =~ "Sign in successful"

      cookie_key = "fz_client_auth"
      conn = fetch_cookies(conn, signed: [cookie_key])
      client_auth_data = conn.cookies[cookie_key]

      assert client_auth_data[:state] == "STATE"
      assert client_auth_data[:fragment]
      assert client_auth_data[:actor_name] == actor.name
      assert client_auth_data[:identity_provider_identifier] == identity.provider_identifier
    end

    test "persists account into list of recent accounts when credentials are valid", %{
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

      assert %{"fz_recent_account_ids" => fz_recent_account_ids} = conn.cookies
      assert :erlang.binary_to_term(fz_recent_account_ids) == [identity.account_id]
    end
  end

  describe "request_email_otp/2" do
    test "redirects to account root when required params aren't provided", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      params = %{"foo" => "bar"}
      conn = post(conn, ~p"/#{account}/sign_in/providers/#{provider}/request_email_otp", params)

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) =~ "Invalid request."
    end

    test "sends a login link to the user email", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/request_email_otp",
          %{
            "email" => %{
              "provider_identifier" => identity.provider_identifier
            }
          }
        )

      assert_email_sent(fn email ->
        assert email.subject == "Firezone sign in token"

        verify_sign_in_token_path =
          ~p"/#{account}/sign_in/providers/#{provider.id}/verify_sign_in_token"

        assert email.text_body =~ "#{verify_sign_in_token_path}"
        assert email.text_body =~ "identity_id=#{identity.id}"
        assert email.text_body =~ "secret="
      end)

      assert redirected_to(conn) =~
               "/#{account.id}/sign_in/providers/email/#{provider.id}?" <>
                 "signed_provider_identifier="
    end

    test "rate limits the emails", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      for _ <- 1..3 do
        post(conn, ~p"/#{account}/sign_in/providers/#{provider}/request_email_otp", %{
          "email" => %{
            "provider_identifier" => identity.provider_identifier
          }
        })

        assert_email_sent(fn email ->
          assert email.subject == "Firezone sign in token"
        end)
      end

      post(conn, ~p"/#{account}/sign_in/providers/#{provider}/request_email_otp", %{
        "email" => %{
          "provider_identifier" => identity.provider_identifier
        }
      })

      refute_email_sent()
    end

    test "stores email nonce and redirect params in the cookie", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        post(
          conn,
          ~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/request_email_otp",
          %{
            "as" => "client",
            "nonce" => "NONCE",
            "state" => "STATE",
            "email" => %{
              "provider_identifier" => identity.provider_identifier
            }
          }
        )

      cookie_key = "fz_auth_state_#{provider.id}"
      conn = fetch_cookies(conn, signed: [cookie_key])

      assert {nonce, provider_identifier, params} =
               conn.cookies[cookie_key]
               |> :erlang.binary_to_term([:safe])

      assert is_binary(nonce)
      assert provider_identifier == identity.provider_identifier

      assert %{
               "as" => "client",
               "nonce" => "NONCE",
               "state" => "STATE"
             } = params
    end

    test "redirects to the sign in page if provider is not found", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider_id = Ecto.UUID.generate()

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider_id}/request_email_otp",
          %{"email" => %{"provider_identifier" => "foo@bar.com"}}
        )

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) == "You may not use this method to sign in."
    end

    test "redirects to the sign in page if email is invalid", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider_id = Ecto.UUID.generate()

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider_id}/request_email_otp",
          %{"email" => %{"provider_identifier" => "foo"}}
        )

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) == "Invalid email address."
    end

    test "does not return error if identity is not found", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)

      conn =
        post(
          conn,
          ~p"/#{account.id}/sign_in/providers/#{provider.id}/request_email_otp",
          %{"email" => %{"provider_identifier" => "foo@bar"}}
        )

      assert uri = conn |> redirected_to() |> URI.parse()
      assert uri.path == ~p"/#{account.id}/sign_in/providers/email/#{provider.id}"

      assert %{"signed_provider_identifier" => signed_provider_identifier} =
               URI.decode_query(uri.query)

      assert Plug.Crypto.verify(
               conn.secret_key_base,
               "signed_provider_identifier",
               signed_provider_identifier
             ) == {:ok, "foo@bar"}

      assert {nonce, "foo@bar", %{}} =
               conn.cookies["fz_auth_state_#{provider.id}"]
               |> :erlang.binary_to_term()

      assert String.length(nonce) == 259
    end
  end

  describe "verify_sign_in_token/2" do
    setup %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {conn_with_cookie, secret} = put_email_auth_state(conn, account, provider, identity)

      %{
        account: account,
        provider: provider,
        actor: actor,
        identity: identity,
        email_secret: secret,
        conn_with_cookie: conn_with_cookie
      }
    end

    test "redirects to account root if required params aren't provided", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      params = %{"foo" => "bar"}

      conn =
        get(conn, ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", params)

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) =~ "Invalid request."
    end

    test "redirects with an error when auth state for given provider does not exist", %{
      account: account,
      conn_with_cookie: conn
    } do
      provider_id = Ecto.UUID.generate()

      conn =
        get(conn, ~p"/#{account}/sign_in/providers/#{provider_id}/verify_sign_in_token", %{
          "identity_id" => Ecto.UUID.generate(),
          "secret" => "foo"
        })

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) == "The sign in token is expired."
    end

    test "uses redirect params from the request query when auth state does not exist", %{
      account: account,
      provider: provider,
      conn: conn
    } do
      conn =
        get(conn, ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => Ecto.UUID.generate(),
          "secret" => "foo",
          "as" => "client",
          "redirect_to" => "/foo"
        })

      assert redirected_to = redirected_to(conn)
      assert redirected_to =~ "as=client"
      assert redirected_to =~ "redirect_to=%2Ffoo"
    end

    test "redirects with an error when provider is deleted", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider
    } do
      provider = Fixtures.Auth.delete_provider(provider)

      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => Ecto.UUID.generate(),
          "secret" => Ecto.UUID.generate()
        })

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) == "You may not use this method to sign in."
    end

    test "redirects with an error when provider is disabled", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider
    } do
      provider = Fixtures.Auth.disable_provider(provider)

      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => Ecto.UUID.generate(),
          "secret" => Ecto.UUID.generate()
        })

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) == "You may not use this method to sign in."
    end

    test "redirects back to the form when sign in token is invalid", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider,
      identity: identity
    } do
      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => "bar"
        })

      assert redirected_to(conn) =~
               ~p"/#{account}/sign_in/providers/email/#{provider}" <>
                 "?signed_provider_identifier="

      assert flash(conn, :error) == "The sign in token is invalid or expired."
    end

    test "keeps redirect params when sign in token is invalid", %{
      conn: conn,
      account: account,
      provider: provider,
      identity: identity
    } do
      redirect_params = %{
        "as" => "client",
        "nonce" => "NONCE",
        "state" => "STATE",
        "redirect_to" => "/#{account.slug}/foo"
      }

      {conn_with_cookie, _secret} =
        put_email_auth_state(conn, account, provider, identity, redirect_params)

      conn =
        conn_with_cookie
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => "bar"
        })

      assert uri = conn |> redirected_to() |> URI.parse()
      assert uri.path == ~p"/#{account}/sign_in/providers/email/#{provider}"

      assert %{
               "as" => "client",
               "nonce" => "NONCE",
               "state" => "STATE",
               "redirect_to" => redirect_to,
               "signed_provider_identifier" => signed_provider_identifier
             } = URI.decode_query(uri.query)

      assert redirect_to == "/#{account.slug}/foo"

      assert Plug.Crypto.verify(
               conn.secret_key_base,
               "signed_provider_identifier",
               signed_provider_identifier
             ) == {:ok, identity.provider_identifier}

      assert flash(conn, :error) == "The sign in token is invalid or expired."
    end

    test "redirects to the signed in path when credentials are valid", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider,
      identity: identity,
      email_secret: email_secret
    } do
      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => email_secret
        })

      assert conn.assigns.flash == %{}
      assert redirected_to(conn) == ~p"/#{account}/sites"
    end

    test "emailed part of the token is not case sensitive", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider,
      identity: identity,
      email_secret: email_secret
    } do
      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => String.upcase(email_secret)
        })

      assert conn.assigns.flash == %{}
      assert redirected_to(conn) == ~p"/#{account}/sites"
    end

    test "redirects to the platform link when credentials are valid", %{
      conn: conn,
      account: account,
      provider: provider,
      identity: identity
    } do
      redirect_params = %{
        "as" => "client",
        "nonce" => "NONCE",
        "state" => "STATE",
        "provider_identifier" => identity.id,
        # this param must be ignored
        "redirect_to" => "/#{account.slug}/foo"
      }

      {conn_with_cookie, secret} =
        put_email_auth_state(conn, account, provider, identity, redirect_params)

      conn =
        conn_with_cookie
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => secret
        })

      client_auth_cookie_key = "fz_client_auth"

      assert conn.assigns.flash == %{}
      refute Map.has_key?(conn.cookies, "fz_auth_state_#{provider.id}")
      assert Map.has_key?(conn.cookies, client_auth_cookie_key)

      assert response = response(conn, 200)
      assert response =~ "Sign in successful"

      conn = fetch_cookies(conn, signed: [client_auth_cookie_key])
      client_auth_data = conn.cookies[client_auth_cookie_key]

      assert client_auth_data[:state] == redirect_params["state"]
      assert not is_nil(client_auth_data[:fragment])
      assert client_auth_data[:actor_name] == Repo.preload(identity, :actor).actor.name
      assert client_auth_data[:identity_provider_identifier] == identity.provider_identifier
    end

    test "appends a new valid session when credentials are valid", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider,
      identity: identity,
      email_secret: email_secret
    } do
      conn =
        conn
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => email_secret
          }
        )

      assert %{
               "sessions" => [
                 {context_type, account_id, session_token}
               ]
             } = conn.private.plug_session

      assert account_id == account.id

      context = %Domain.Auth.Context{
        type: context_type,
        remote_ip: conn.remote_ip,
        user_agent: conn.assigns.user_agent
      }

      assert {:ok, subject} = Domain.Auth.authenticate(session_token, context)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == "testing"
      assert subject.identity.last_seen_remote_ip.address == {127, 0, 0, 1}
      assert subject.identity.last_seen_at
    end

    test "persists account into list of recent accounts when credentials are valid", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider,
      identity: identity,
      email_secret: email_secret
    } do
      conn =
        conn
        |> get(
          ~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token",
          %{
            "identity_id" => identity.id,
            "secret" => email_secret
          }
        )

      assert %{"fz_recent_account_ids" => fz_recent_account_ids} = conn.cookies
      assert :erlang.binary_to_term(fz_recent_account_ids) == [identity.account_id]
    end

    test "resets the rate limit for signed in identity", %{
      conn_with_cookie: conn,
      account: account,
      provider: provider,
      identity: identity,
      email_secret: email_secret
    } do
      key = {:sign_in_link, identity.id}
      Domain.Mailer.RateLimiter.rate_limit(key, 3, 60_000, fn -> :ok end)

      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
          "identity_id" => identity.id,
          "secret" => String.upcase(email_secret)
        })

      assert conn.assigns.flash == %{}
      assert redirected_to(conn) == ~p"/#{account}/sites"

      refute :ets.tab2list(Domain.Mailer.RateLimiter.ETS)
             |> Enum.any?(fn {ets_key, _, _} -> ets_key == key end)
    end
  end

  describe "redirect_to_idp/2" do
    test "redirects with an error when provider does not exist", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/#{account_id}/sign_in/providers/#{provider_id}/redirect")

      assert redirected_to(conn) == "/#{account_id}"
      assert flash(conn, :error) == "You may not use this method to sign in."
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

      {params, state, verifier} =
        conn.cookies["fz_auth_state_#{provider.id}"] |> :erlang.binary_to_term()

      assert params == %{}

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

    test "persists redirect params", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      redirect_params = %{
        "as" => "client",
        "nonce" => "NONCE",
        "state" => "STATE",
        "redirect_to" => "/#{account.slug}/foo"
      }

      conn =
        get(conn, ~p"/#{account.id}/sign_in/providers/#{provider.id}/redirect", redirect_params)

      assert to = redirected_to(conn)
      uri = URI.parse(to)
      assert uri.host == "localhost"
      assert uri.path == "/authorize"

      callback_url =
        url(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback")

      {params, state, verifier} =
        conn.cookies["fz_auth_state_#{provider.id}"]
        |> :erlang.binary_to_term([:safe])

      assert params == redirect_params

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
    setup %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      {conn_with_cookie, state, verifier} = put_idp_auth_state(conn, account, provider)

      %{
        account: account,
        provider: provider,
        bypass: bypass,
        state: state,
        verifier: verifier,
        conn_with_cookie: conn_with_cookie
      }
    end

    test "redirects to account root when required params aren't provided", %{
      account: account,
      provider: provider,
      conn: conn
    } do
      params = %{
        "foo" => "bar",
        "error" => "an error",
        "error_description" => "an error description"
      }

      conn =
        get(conn, ~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", params)

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "Invalid request."
      assert flash(conn, :error) =~ "error: an error. error_description: an error description"
    end

    test "redirects with an error when state cookie does not exist", %{
      account: account,
      provider: provider,
      state: state,
      conn: conn
    } do
      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/handle_callback", %{
          "state" => state,
          "code" => "bar"
        })

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) == "Your session has expired, please try again."
    end

    test "redirects with an error when provider is deleted", %{
      account: account,
      provider: provider,
      state: state,
      conn_with_cookie: conn
    } do
      provider = Fixtures.Auth.delete_provider(provider)

      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/handle_callback", %{
          "state" => state,
          "code" => "bar"
        })

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) == "You may not use this method to sign in."
    end

    test "redirects with an error when provider is disabled", %{
      account: account,
      provider: provider,
      state: state,
      conn_with_cookie: conn
    } do
      provider = Fixtures.Auth.disable_provider(provider)

      conn =
        conn
        |> get(~p"/#{account}/sign_in/providers/#{provider}/handle_callback", %{
          "state" => state,
          "code" => "bar"
        })

      assert redirected_to(conn) == ~p"/#{account}"
      assert flash(conn, :error) == "You may not use this method to sign in."
    end

    test "redirects with an error when state is invalid", %{
      account: account,
      provider: provider,
      conn: conn
    } do
      {conn, _state, _verifier} =
        put_idp_auth_state(conn, account, provider, %{
          as: "client",
          state: "STATE",
          nonce: "NONCE"
        })

      conn =
        conn
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => "foo",
          "code" => "MyFakeCode"
        })

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) == "Your session has expired, please try again."
    end

    test "redirects with an error when token is invalid", %{
      account: account,
      provider: provider,
      bypass: bypass,
      conn: conn
    } do
      redirect_params = %{
        as: "client",
        state: "STATE",
        nonce: "NONCE"
      }

      {conn, state, _verifier} = put_idp_auth_state(conn, account, provider, redirect_params)

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => "foo"})

      conn =
        conn
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      redirected_to = redirected_to(conn)
      assert redirected_to =~ ~p"/#{account.id}"
      assert redirected_to =~ "as=client"
      assert redirected_to =~ "state=STATE"
      assert redirected_to =~ "nonce=NONCE"
      assert flash(conn, :error) == "You may not authenticate to this account."
    end

    test "redirects to the redirect url on success", %{
      account: account,
      provider: provider,
      bypass: bypass,
      conn: conn
    } do
      {conn, state, _verifier} =
        put_idp_auth_state(conn, account, provider, %{
          redirect_to: "/#{account.slug}/foo"
        })

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider
        )

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      assert redirected_to(conn) == "/#{account.slug}/foo"
    end

    test "redirects clients to sign in success page on success", %{
      account: account,
      provider: provider,
      bypass: bypass,
      conn: conn
    } do
      {conn, state, _verifier} =
        put_idp_auth_state(conn, account, provider, %{
          as: "client",
          state: "STATE",
          nonce: "NONCE"
        })

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_user],
          account: account,
          provider: provider
        )

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      cookie_key = "fz_client_auth"
      conn = fetch_cookies(conn, signed: [cookie_key])
      client_auth_data = conn.cookies[cookie_key]

      assert response = response(conn, 200)
      assert response =~ "Sign in successful"

      assert client_auth_data[:state] == "STATE"
      assert not is_nil(client_auth_data[:fragment])
      assert client_auth_data[:actor_name] == Repo.preload(identity, :actor).actor.name
      assert client_auth_data[:identity_provider_identifier] == identity.provider_identifier
    end

    test "persists the valid auth token in session on success", %{
      account: account,
      provider: provider,
      bypass: bypass,
      state: state,
      conn_with_cookie: conn
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

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      assert %{
               "preferred_locale" => "en_US",
               "sessions" => [{context_type, _account_id, encoded_token}]
             } = conn.private.plug_session

      context = %Domain.Auth.Context{
        type: context_type,
        remote_ip: conn.remote_ip,
        user_agent: conn.assigns.user_agent
      }

      assert {:ok, subject} = Domain.Auth.authenticate(encoded_token, context)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == context.user_agent
      assert subject.identity.last_seen_remote_ip.address == context.remote_ip
      assert subject.identity.last_seen_at
    end

    test "persists account into list of recent accounts when credentials are valid", %{
      account: account,
      provider: provider,
      bypass: bypass,
      state: state,
      conn_with_cookie: conn
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

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account.id}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => state,
          "code" => "MyFakeCode"
        })

      assert %{"fz_recent_account_ids" => fz_recent_account_ids} = conn.cookies
      assert :erlang.binary_to_term(fz_recent_account_ids) == [identity.account_id]
    end
  end

  describe "sign_out/2" do
    test "redirects to the sign in page and renews the session", %{conn: conn} do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        conn
        |> authorize_conn(identity)
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) == url(~p"/#{account}")
      assert conn.private.plug_session == %{"preferred_locale" => "en_US", "sessions" => []}
    end

    test "redirects to the IdP sign out page", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      conn =
        conn
        |> authorize_conn(identity)
        |> get(~p"/#{account}/sign_out")

      post_redirect_url = URI.encode_www_form(url(~p"/#{account}"))

      assert redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://example.com"
      assert redirect_url =~ "id_token_hint="
      assert redirect_url =~ "client_id=#{provider.adapter_config["client_id"]}"
      assert redirect_url =~ "post_logout_redirect_uri=#{post_redirect_url}"
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      conn = authorize_conn(conn, identity)

      live_socket_id = "sessions:#{conn.assigns.subject.token_id}"
      Web.Endpoint.subscribe(live_socket_id)

      conn =
        conn
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) =~ ~p"/#{account}"

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if user is already logged out", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      conn =
        conn
        |> put_session(:preferred_locale, "en_US")
        |> get(~p"/#{account}/sign_out")

      assert redirected_to(conn) =~ ~p"/#{account}"
      assert conn.private.plug_session == %{"preferred_locale" => "en_US", "sessions" => []}

      refute Map.has_key?(conn.cookies, "fz_recent_account_ids")
    end

    test "redirects to client-specific post sign out url", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      conn = get(conn, ~p"/#{account}/sign_out", %{as: "client", state: "STATE"})
      assert redirected_to(conn) == "firezone://handle_client_sign_out_callback?state=STATE"
    end
  end

  test "keeps up to 5 recent accounts the used signed in to", %{conn: conn} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    {conn, account_ids} =
      Enum.reduce(1..6, {conn, []}, fn _i, {conn, account_ids} ->
        account = Fixtures.Accounts.create_account()
        provider = Fixtures.Auth.create_email_provider(account: account)

        identity =
          Fixtures.Auth.create_identity(
            actor: [type: :account_admin_user],
            account: account,
            provider: provider
          )

        {conn, secret} = put_email_auth_state(conn, account, provider, identity)

        authorized_conn =
          conn
          |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
            "identity_id" => identity.id,
            "secret" => secret
          })
          |> fetch_cookies()

        %{value: signed_state} = authorized_conn.resp_cookies["fz_recent_account_ids"]
        conn = put_req_cookie(conn, "fz_recent_account_ids", signed_state)

        {conn, [account.id] ++ account_ids}
      end)

    conn = %{conn | secret_key_base: Web.Endpoint.config(:secret_key_base)}
    conn = fetch_cookies(conn, signed: ["fz_recent_account_ids"])
    assert %{"fz_recent_account_ids" => fz_recent_account_ids} = conn.cookies
    recent_account_ids = :erlang.binary_to_term(fz_recent_account_ids)
    assert length(recent_account_ids) == 5
    assert recent_account_ids == Enum.take(account_ids, 5)
  end
end
