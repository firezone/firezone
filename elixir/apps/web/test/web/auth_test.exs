defmodule Web.AuthTest do
  use Web.ConnCase, async: true
  import Web.Auth

  setup %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    conn = assign(conn, :account, account)
    context = Fixtures.Auth.build_context(type: :browser)
    nonce = "nonce"

    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    provider = Fixtures.Auth.create_email_provider(account: account)

    # Admin
    admin_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    admin_identity =
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: admin_actor)

    admin_identity = %{admin_identity | actor: admin_actor}

    {:ok, admin_token} = Domain.Auth.create_token(admin_identity, context, nonce, nil)
    admin_encoded_fragment = Domain.Crypto.encode_token_fragment!(admin_token)

    admin_subject =
      Fixtures.Auth.create_subject(
        provider: provider,
        identity: admin_identity,
        context: context,
        token: admin_token
      )

    # User
    user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

    user_identity =
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: user_actor)

    user_identity = %{user_identity | actor: user_actor}

    {:ok, user_token} = Domain.Auth.create_token(user_identity, context, nonce, nil)
    user_encoded_fragment = Domain.Crypto.encode_token_fragment!(user_token)

    user_subject =
      Fixtures.Auth.create_subject(
        provider: provider,
        identity: user_identity,
        context: context,
        token: user_token
      )

    %{
      conn: conn,
      account: account,
      context: context,
      provider: provider,
      nonce: nonce,
      admin_actor: admin_actor,
      admin_identity: admin_identity,
      admin_token: admin_token,
      admin_encoded_fragment: admin_encoded_fragment,
      admin_subject: admin_subject,
      user_actor: user_actor,
      user_identity: user_identity,
      user_token: user_token,
      user_encoded_fragment: user_encoded_fragment,
      user_subject: user_subject
    }
  end

  describe "put_account_session/4" do
    test "persists a browser token in session", %{
      conn: conn,
      account: account,
      user_encoded_fragment: encoded_token
    } do
      conn = put_account_session(conn, :browser, account.id, encoded_token)
      assert get_session(conn, :sessions) == [{:browser, account.id, encoded_token}]
    end

    test "does not persist a client token in session", %{
      conn: conn,
      account: account,
      nonce: nonce,
      user_encoded_fragment: encoded_fragment
    } do
      encoded_token = nonce <> encoded_fragment
      conn = put_account_session(conn, :client, account.id, encoded_token)
      assert get_session(conn, "sessions", []) == []
    end

    test "updates an existing account_id session", %{
      conn: conn,
      account: account,
      user_encoded_fragment: encoded_token
    } do
      conn =
        conn
        |> put_session(:sessions, [])
        |> put_account_session(:browser, account.id, encoded_token)
        |> put_account_session(:browser, account.id, "foo")

      assert get_session(conn, "sessions") == [{:browser, account.id, "foo"}]
    end

    test "appends a new tokens to a session", %{
      conn: conn
    } do
      account_id1 = Ecto.UUID.generate()
      account_id2 = Ecto.UUID.generate()

      session = {:client, account_id1, "buz"}

      conn =
        conn
        |> put_session(:sessions, [session])
        |> put_account_session(:browser, account_id1, "foo")
        |> put_account_session(:browser, account_id2, "bar")

      assert get_session(conn, "sessions") == [
               session,
               {:browser, account_id1, "foo"},
               {:browser, account_id2, "bar"}
             ]
    end

    test "doesn't store more than 6 last sessions", %{
      conn: conn,
      account: account
    } do
      sessions =
        for i <- 1..15 do
          {:browser, Ecto.UUID.generate(), "foo_#{i}"}
        end

      conn =
        conn
        |> put_session(:sessions, sessions)
        |> put_account_session(:browser, account.id, "bar")

      assert get_session(conn, "sessions") ==
               Enum.take(sessions, -5) ++ [{:browser, account.id, "bar"}]
    end
  end

  describe "take_sign_in_params/1" do
    test "takes params used for sign in" do
      for key <- ["as", "state", "nonce", "redirect_to"] do
        assert take_sign_in_params(%{key => "foo"}) == %{key => "foo"}
      end
    end

    test "ignores other params" do
      assert take_sign_in_params(%{"foo" => "bar"}) == %{}
    end
  end

  describe "fetch_auth_context_type!/1" do
    test "takes context type from as param" do
      assert fetch_auth_context_type!(%{"as" => "client"}) == :client
      assert fetch_auth_context_type!(%{"as" => "browser"}) == :browser
      assert fetch_auth_context_type!(%{"as" => "other"}) == :browser
      assert fetch_auth_context_type!(nil) == :browser
    end
  end

  describe "fetch_token_nonce!/1" do
    test "takes nonce from nonce param" do
      assert fetch_token_nonce!(%{"nonce" => "foo"}) == "foo"
      assert fetch_token_nonce!(%{"nonce" => ""}) == ""
      assert fetch_token_nonce!(nil) == nil
    end
  end

  describe "signed_in/6" do
    test "appends the recent account ids", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      admin_identity: identity
    } do
      conn =
        signed_in(conn, provider, identity, context, "foo", %{})
        |> fetch_cookies()

      recent_account_ids =
        conn.cookies["recent_account_ids"]
        |> :erlang.binary_to_term()

      assert recent_account_ids == [account.id]
    end

    test "persists the token in session", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      nonce: nonce,
      admin_identity: admin_identity,
      admin_encoded_fragment: admin_encoded_fragment
    } do
      admin_encoded_token = nonce <> admin_encoded_fragment

      conn =
        %{conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> fetch_flash()
        |> signed_in(provider, admin_identity, context, admin_encoded_token, %{})

      assert get_session(conn, "sessions") == [{context.type, account.id, admin_encoded_token}]
    end

    test "renders error when trying to sign in client without client params", %{
      conn: init_conn,
      context: context,
      account: account,
      provider: provider,
      user_identity: user_identity,
      user_encoded_fragment: user_encoded_fragment
    } do
      context = %{context | type: :client}

      conn =
        %{init_conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> fetch_flash()
        |> signed_in(provider, user_identity, context, user_encoded_fragment, %{})

      assert redirected_to(conn) == ~p"/#{account}"

      assert conn.assigns.flash["error"] ==
               "You must have the admin role in Firezone to sign in to the admin portal."

      conn =
        %{init_conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> fetch_flash()
        |> signed_in(provider, user_identity, context, user_encoded_fragment, %{
          "as" => "client",
          "state" => "STATE"
        })

      assert redirected_to(conn) == ~p"/#{account}"

      assert conn.assigns.flash["error"] ==
               "You must have the admin role in Firezone to sign in to the admin portal."

      conn =
        %{init_conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> fetch_flash()
        |> signed_in(provider, user_identity, context, user_encoded_fragment, %{
          "as" => "client",
          "nonce" => "NONCE"
        })

      assert redirected_to(conn) == ~p"/#{account}"

      assert conn.assigns.flash["error"] ==
               "You must have the admin role in Firezone to sign in to the admin portal."
    end

    test "redirects non-admin users to the sign in success page for client contexts", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      nonce: nonce,
      user_identity: identity,
      user_encoded_fragment: encoded_fragment
    } do
      context = %{context | type: :client}

      redirect_params = %{"as" => "client", "state" => "STATE", "nonce" => nonce}

      response =
        %{conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> put_private(:phoenix_endpoint, @endpoint)
        |> Web.Plugs.SecureHeaders.call([])
        |> fetch_flash()
        |> signed_in(provider, identity, context, encoded_fragment, redirect_params)
        |> Phoenix.ConnTest.response(200)

      assert response =~ "Sign in successful"

      assert response
             |> Floki.parse_fragment!()
             |> Floki.attribute("meta", "content")
             |> Enum.any?(fn value ->
               &(&1 == "0; url=/#{account.slug}/sign_in/client_redirect")
             end)
    end

    test "redirects admin users to the sign in success page for client contexts", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      nonce: nonce,
      admin_identity: identity,
      admin_encoded_fragment: encoded_fragment
    } do
      context = %{context | type: :client}

      redirect_params = %{"as" => "client", "state" => "STATE", "nonce" => nonce}

      response =
        %{conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> put_private(:phoenix_endpoint, @endpoint)
        |> Web.Plugs.SecureHeaders.call([])
        |> fetch_flash()
        |> signed_in(provider, identity, context, encoded_fragment, redirect_params)
        |> Phoenix.ConnTest.response(200)

      assert response =~ "Sign in successful"

      assert response
             |> Floki.parse_fragment!()
             |> Floki.attribute("meta", "content")
             |> Enum.any?(fn value ->
               &(&1 == "0; url=/#{account.slug}/sign_in/client_redirect")
             end)
    end

    test "redirects admin user to the post-login path for browser contexts", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      admin_identity: identity,
      admin_encoded_fragment: encoded_fragment
    } do
      # for browser contexts those params must be ignored
      redirect_params = %{"state" => "STATE", "nonce" => "NONCE"}

      redirected_to =
        conn
        |> signed_in(provider, identity, context, encoded_fragment, redirect_params)
        |> redirected_to()

      assert redirected_to == ~p"/#{account}/sites"
    end

    test "redirects regular users back to sign in page for browser contexts", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      user_identity: identity,
      user_encoded_fragment: encoded_fragment
    } do
      conn =
        %{conn | path_params: %{"account_id_or_slug" => account.slug}}
        |> fetch_flash()
        |> signed_in(provider, identity, context, encoded_fragment, %{})

      assert redirected_to(conn) == ~p"/#{account}"

      assert conn.assigns.flash["error"] ==
               "You must have the admin role in Firezone to sign in to the admin portal."
    end

    test "redirects admin user to the return path path for browser contexts", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      admin_identity: identity,
      admin_encoded_fragment: encoded_fragment
    } do
      assert conn
             |> signed_in(provider, identity, context, encoded_fragment, %{
               "redirect_to" => "/#{account.id}/foo"
             })
             |> redirected_to() == "/#{account.id}/foo"

      assert conn
             |> signed_in(provider, identity, context, encoded_fragment, %{
               "redirect_to" => "/#{account.slug}/foo"
             })
             |> redirected_to() == "/#{account.slug}/foo"
    end

    test "return path does not allow to redirect user outside of account", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      admin_identity: identity,
      admin_encoded_fragment: encoded_fragment
    } do
      for destination <- [
            "/foo",
            "http://example.com/",
            "/#{Ecto.UUID.generate()}/foo",
            "/foo/bar",
            "foo"
          ] do
        redirect_params = %{"redirect_to" => destination}

        assert conn
               |> signed_in(provider, identity, context, encoded_fragment, redirect_params)
               |> redirected_to() == ~p"/#{account}/sites"
      end
    end

    test "post-login redirect path ignores url params", %{
      conn: conn,
      context: context,
      account: account,
      provider: provider,
      admin_identity: identity,
      admin_encoded_fragment: encoded_fragment
    } do
      redirected_to =
        %{conn | path_params: %{"account_id_or_slug" => "foo"}}
        |> signed_in(provider, identity, context, encoded_fragment, %{})
        |> redirected_to()

      assert redirected_to == ~p"/#{account}/sites"
    end
  end

  describe "sign_out/1" do
    test "erases session with given account_id and redirects to sign in page", %{
      conn: conn,
      account: account
    } do
      not_deleted_session = {:browser, Ecto.UUID.generate(), "baz"}

      conn =
        conn
        |> assign(:account, account)
        |> put_session(:sessions, [
          {:browser, account.id, "foo"},
          not_deleted_session,
          {:client, account.id, "bar"}
        ])
        |> fetch_cookies()
        |> sign_out(%{})

      assert get_session(conn, :sessions) == [not_deleted_session]

      assert redirected_to(conn, 302) == "http://localhost:13100/#{account.slug}"
    end

    test "redirects to the sign in page even on invalid account ids", %{
      conn: conn,
      account: account,
      admin_encoded_fragment: encoded_fragment
    } do
      account_slug = "foo"
      session = {:browser, account.id, encoded_fragment}

      conn =
        conn
        |> assign(:account, nil)
        |> put_session(:sessions, [session])
        |> fetch_cookies()
        |> sign_out(%{"account_id_or_slug" => account_slug})

      assert get_session(conn, :sessions) == [session]

      assert redirected_to(conn, 302) =~ ~p"/#{account_slug}"
    end

    test "redirects to client sign out deep link", %{
      conn: conn,
      account: account
    } do
      conn =
        sign_out(conn, %{
          "account_id_or_slug" => account.slug,
          "as" => "client",
          "state" => "STATE"
        })

      assert redirected_to(conn, 302) == "firezone://handle_client_sign_out_callback?state=STATE"
    end

    test "erases session, session cookie and redirects to IdP sign out page", %{
      conn: conn,
      account: account,
      admin_encoded_fragment: encoded_fragment
    } do
      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      subject = Fixtures.Auth.create_subject(identity: identity)

      conn =
        conn
        |> assign(:account, account)
        |> put_session(:sessions, [{:browser, account.id, encoded_fragment}])
        |> fetch_cookies()
        |> sign_out(%{"account_id_or_slug" => account.id})

      assert get_session(conn, :sessions) == []

      assert redirected_to(conn, 302) =~ ~p"/#{subject.account}"
    end

    test "post-redirects from IdP sign out page to client deep link", %{
      conn: conn,
      account: account,
      admin_encoded_fragment: encoded_fragment
    } do
      conn =
        conn
        |> assign(:account, account)
        |> put_session(:sessions, [{:browser, account.id, encoded_fragment}])
        |> fetch_cookies()
        |> sign_out(%{
          "account_id_or_slug" => account.slug,
          "as" => "client",
          "state" => "STATE"
        })

      assert get_session(conn, :sessions) == []

      assert redirected_to(conn, 302) == "firezone://handle_client_sign_out_callback?state=STATE"
    end

    test "keeps preferred_locale session value", %{account: account, conn: conn} do
      conn =
        conn
        |> assign(:account, account)
        |> put_session(:preferred_locale, "uk_UA")
        |> fetch_cookies()
        |> sign_out("")

      assert get_session(conn, :preferred_locale) == "uk_UA"
    end

    test "deletes token", %{
      account: account,
      admin_subject: subject,
      conn: conn
    } do
      live_socket_id = Domain.Tokens.socket_id(subject.token_id)

      conn
      |> assign(:account, account)
      |> assign(:subject, subject)
      |> put_private(:phoenix_endpoint, @endpoint)
      |> put_session(:live_socket_id, live_socket_id)
      |> sign_out(%{})

      refute(Repo.get(Domain.Token, subject.token_id))
    end
  end

  describe "fetch_user_agent/2" do
    test "assigns user agent value to connection assigns", %{conn: conn, user_agent: user_agent} do
      conn = fetch_user_agent(conn, [])
      assert conn.assigns.user_agent == user_agent
    end

    test "does nothing when user agent header is not set" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})

      conn = fetch_user_agent(conn, [])
      refute Map.has_key?(conn.assigns, :user_agent)
    end
  end

  describe "fetch_subject/2" do
    setup context do
      %{conn: assign(context.conn, :user_agent, context.admin_subject.context.user_agent)}
    end

    test "authenticates user from session of browser type by default", %{
      conn: conn,
      context: context,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:sessions, [{context.type, subject.account.id, nonce <> encoded_fragment}])
        |> assign(:account, subject.account)
        |> fetch_subject([])

      assert conn.assigns.subject.identity.id == subject.identity.id
      assert conn.assigns.subject.actor.id == subject.actor.id
      assert conn.assigns.subject.account.id == subject.account.id

      assert get_session(conn, "live_socket_id") == "sessions:#{subject.token_id}"
    end

    test "authenticates user from session of client type when it's set in query param", %{
      conn: conn,
      context: context,
      nonce: nonce,
      account: account,
      admin_actor: admin_actor,
      admin_identity: admin_identity
    } do
      context = %{context | type: :client}
      {:ok, client_token} = Domain.Auth.create_token(admin_identity, context, nonce, nil)
      encoded_fragment = Domain.Crypto.encode_token_fragment!(client_token)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => account.id},
            params: %{"as" => "client"},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> assign(:account, account)
        |> fetch_subject([])

      assert conn.assigns.subject.identity.id == admin_identity.id
      assert conn.assigns.subject.actor.id == admin_actor.id
      assert conn.assigns.subject.account.id == account.id

      assert get_session(conn, "live_socket_id") == "sessions:#{conn.assigns.subject.token_id}"
    end

    test "does not try to authenticate user of a different context type", %{
      conn: conn,
      context: context,
      nonce: nonce,
      account: account,
      admin_identity: admin_identity
    } do
      context = %{context | type: :client}
      {:ok, client_token} = Domain.Auth.create_token(admin_identity, context, nonce, nil)
      encoded_fragment = Domain.Crypto.encode_token_fragment!(client_token)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => account.id},
            query_params: %{"as" => "browser"},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> assign(:account, account)
        |> fetch_subject([])

      refute Map.has_key?(conn.assigns, :subject)
    end

    test "puts load balancer GeoIP headers to subject context", %{
      conn: conn,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_req_header("x-geo-location-region", "Ukraine")
        |> put_req_header("x-geo-location-city", "Kyiv")
        |> put_req_header("x-geo-location-coordinates", "50.4333,30.5167")
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> assign(:account, subject.account)
        |> fetch_subject([])

      assert conn.assigns.subject.context.remote_ip_location_region == "Ukraine"
      assert conn.assigns.subject.context.remote_ip_location_city == "Kyiv"
      assert conn.assigns.subject.context.remote_ip_location_lat == 50.4333
      assert conn.assigns.subject.context.remote_ip_location_lon == 30.5167
    end

    test "puts country coordinates to subject assign", %{
      conn: conn,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_req_header("x-geo-location-region", "UA")
        |> delete_req_header("x-geo-location-city")
        |> delete_req_header("x-geo-location-coordinates")
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> assign(:account, subject.account)
        |> fetch_subject([])

      assert conn.assigns.subject.context.remote_ip_location_region == "UA"
      assert conn.assigns.subject.context.remote_ip_location_city == nil
      assert conn.assigns.subject.context.remote_ip_location_lat == 49.0
      assert conn.assigns.subject.context.remote_ip_location_lon == 32.0
    end

    test "does not authenticate to an incorrect account", %{
      conn: conn,
      context: context,
      account: account,
      admin_encoded_fragment: encoded_fragment
    } do
      other_account = Fixtures.Accounts.create_account()

      conn =
        %{conn | remote_ip: {100, 64, 100, 58}}
        |> put_session(:sessions, [{context.type, account.id, encoded_fragment}])
        |> assign(:account, other_account)
        |> fetch_subject([])

      refute Map.has_key?(conn.assigns, :subject)
    end

    test "does not authenticate if data is missing", %{account: account, conn: conn} do
      conn = conn |> assign(:account, account) |> fetch_subject([])
      refute get_session(conn, :sessions)
      refute Map.has_key?(conn.assigns, :subject)
    end

    test "removes invalid tokens from session", %{
      conn: conn,
      account: account
    } do
      conn =
        %{conn | remote_ip: {100, 64, 100, 58}}
        |> put_session(:sessions, [
          {:client, account.id, "valid"},
          {:browser, account.id, "invalid"}
        ])
        |> assign(:account, account)
        |> fetch_subject([])

      refute Map.has_key?(conn.assigns, :subject)

      assert get_session(conn, :sessions) == [{:client, account.id, "valid"}]
    end
  end

  describe "redirect_if_user_is_authenticated/2" do
    test "redirects if user is authenticated to the signed in path", %{
      conn: conn,
      account: account,
      context: context,
      admin_encoded_fragment: encoded_fragment,
      admin_subject: subject
    } do
      conn =
        conn
        |> put_account_session(context.type, account.id, encoded_fragment)
        |> assign(:subject, subject)
        |> fetch_query_params()
        |> redirect_if_user_is_authenticated([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/#{account}/sites"
    end

    test "redirects to sign in success page if client is authenticated", %{
      conn: conn,
      account: account,
      nonce: nonce,
      context: context,
      admin_identity: admin_identity
    } do
      context = %{context | type: :client}

      {:ok, client_token} = Domain.Auth.create_token(admin_identity, context, nonce, nil)
      encoded_fragment = Domain.Crypto.encode_token_fragment!(client_token)
      {:ok, client_subject} = Domain.Auth.authenticate(nonce <> encoded_fragment, context)

      redirect_params = %{"as" => "client", "state" => "STATE", "nonce" => nonce}

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => account.slug},
            params: redirect_params
        }
        |> put_private(:phoenix_endpoint, @endpoint)
        |> Web.Plugs.SecureHeaders.call([])
        |> put_session(:sessions, [{context.type, account.id, encoded_fragment}])
        |> assign(:subject, client_subject)
        |> redirect_if_user_is_authenticated([])

      assert conn.halted

      assert response = response(conn, 200)
      assert response =~ "Sign in successful"

      assert response
             |> Floki.parse_fragment!()
             |> Floki.attribute("meta", "content")
             |> Enum.any?(fn value ->
               &(&1 == "0; url=/#{account.slug}/sign_in/client_redirect")
             end)
    end

    test "does not redirect if user is not authenticated", %{conn: conn} do
      conn = redirect_if_user_is_authenticated(conn, [])
      refute conn.halted
      refute conn.status
    end
  end

  describe "ensure_authenticated/2" do
    setup context do
      %{conn: %{context.conn | path_params: %{"account_id_or_slug" => context.account.slug}}}
    end

    test "redirects if user is not authenticated", %{account: account, conn: conn} do
      conn =
        conn
        |> fetch_flash()
        |> ensure_authenticated([])

      assert conn.halted
      assert redirected_to(conn) =~ ~p"/#{account.slug}?redirect_to="

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must sign in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn, account: account} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> ensure_authenticated([])

      assert halted_conn.halted
      assert redirected_to(halted_conn) == ~p"/#{account}?redirect_to=%2Ffoo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> ensure_authenticated([])

      assert halted_conn.halted
      assert redirected_to(halted_conn) == ~p"/#{account}?redirect_to=%2Ffoo%3Fbar%3Dbaz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> ensure_authenticated([])

      assert halted_conn.halted
      assert redirected_to(halted_conn) == ~p"/#{account}"
    end

    test "does not redirect if user is authenticated", %{conn: conn, admin_subject: subject} do
      conn =
        conn
        |> assign(:subject, subject)
        |> ensure_authenticated([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "on_mount: mount_subject" do
    setup context do
      socket = %Phoenix.LiveView.Socket{
        private: %{
          connect_info: %{
            user_agent: context.admin_subject.context.user_agent,
            peer_data: %{address: {100, 64, 100, 58}},
            x_headers: [
              {"x-geo-location-region", "UA"},
              {"x-geo-location-city", "Kyiv"},
              {"x-geo-location-coordinates", "50.4333,30.5167"}
            ]
          }
        }
      }

      %{socket: socket}
    end

    test "assigns subject based on a valid browser session token", %{
      conn: conn,
      socket: socket,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert updated_socket.assigns.subject.identity.id == subject.identity.id
      assert updated_socket.assigns.subject.context.user_agent == subject.context.user_agent
      assert updated_socket.assigns.subject.context.remote_ip == subject.context.remote_ip
    end

    test "assigns subject based on a valid client session token", %{
      conn: conn,
      socket: socket,
      context: context,
      account: account,
      nonce: nonce,
      admin_actor: admin_actor,
      admin_identity: admin_identity
    } do
      context = %{context | type: :client}
      {:ok, client_token} = Domain.Auth.create_token(admin_identity, context, nonce, nil)
      encoded_fragment = Domain.Crypto.encode_token_fragment!(client_token)

      session =
        conn
        |> assign(:account, account)
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => account.id, "as" => "client"}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)

      assert updated_socket.assigns.subject.identity.id == admin_identity.id
      assert updated_socket.assigns.subject.actor.id == admin_actor.id
      assert updated_socket.assigns.subject.account.id == account.id
    end

    test "puts load balancer GeoIP information to subject context", %{
      conn: conn,
      socket: socket,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, socket} = on_mount(:mount_subject, params, session, socket)

      assert socket.assigns.subject.context.remote_ip_location_region == "UA"
      assert socket.assigns.subject.context.remote_ip_location_city == "Kyiv"
      assert socket.assigns.subject.context.remote_ip_location_lat == 50.4333
      assert socket.assigns.subject.context.remote_ip_location_lon == 30.5167
    end

    test "puts country coordinates to subject context", %{
      conn: conn,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      socket = %Phoenix.LiveView.Socket{
        private: %{
          connect_info: %{
            user_agent: subject.context.user_agent,
            peer_data: %{address: {100, 64, 100, 58}},
            x_headers: [
              {"x-geo-location-region", "UA"}
            ]
          }
        }
      }

      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, socket} = on_mount(:mount_subject, params, session, socket)

      assert socket.assigns.subject.context.remote_ip_location_region == "UA"
      assert socket.assigns.subject.context.remote_ip_location_city == nil
      assert socket.assigns.subject.context.remote_ip_location_lat == 49.0
      assert socket.assigns.subject.context.remote_ip_location_lon == 32.0
    end

    test "assigns nil to subject assign if there isn't a valid session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session_token = "invalid_token"

      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{:client, subject.account.id, session_token}])
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert is_nil(updated_socket.assigns.subject)
    end

    test "assigns nil to subject assign if there isn't a session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session = conn |> get_session()
      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert is_nil(updated_socket.assigns.subject)
    end
  end

  describe "on_mount: assign_account" do
    test "assigns nil to subject assign if account_id doesn't match token", %{
      conn: conn,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          subject: subject
        },
        private: %{
          connect_info: %{
            user_agent: subject.context.user_agent,
            peer_data: %{address: {100, 64, 100, 58}}
          }
        }
      }

      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => Ecto.UUID.generate()}

      assert {:cont, updated_socket} = on_mount(:mount_account, params, session, socket)
      assert is_nil(updated_socket.assigns.account)
    end
  end

  describe "on_mount: ensure_authenticated" do
    setup context do
      socket = %Phoenix.LiveView.Socket{
        endpoint: Web.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}, account: context.account},
        private: %{
          live_temp: %{},
          connect_info: %{
            user_agent: context.admin_subject.context.user_agent,
            peer_data: %{address: {100, 64, 100, 58}}
          }
        }
      }

      %{socket: socket}
    end

    test "authenticates subject based on a valid session_token", %{
      conn: conn,
      socket: socket,
      context: context,
      account: account,
      nonce: nonce,
      admin_subject: subject,
      admin_encoded_fragment: encoded_fragment
    } do
      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:ensure_authenticated, params, session, socket)

      assert updated_socket.assigns.subject.identity.id == subject.identity.id
      assert is_nil(updated_socket.redirected)
    end

    test "redirects to login page if there isn't a valid session_token", %{
      conn: conn,
      socket: socket,
      nonce: nonce,
      admin_subject: subject
    } do
      session_token = "invalid_token"

      session =
        conn
        |> assign(:account, subject.account)
        |> put_session(:sessions, [{:browser, subject.account.id, nonce <> session_token}])
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.slug}

      assert {:halt, updated_socket} = on_mount(:ensure_authenticated, params, session, socket)

      assert is_nil(updated_socket.assigns.subject)

      assert updated_socket.redirected ==
               {:redirect, %{status: 302, to: ~p"/#{subject.account.slug}"}}
    end

    test "redirects to login page if there isn't a session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session = conn |> get_session()
      params = %{"account_id_or_slug" => subject.account.slug}

      assert {:halt, updated_socket} = on_mount(:ensure_authenticated, params, session, socket)

      assert is_nil(updated_socket.assigns.subject)

      assert updated_socket.redirected ==
               {:redirect, %{status: 302, to: ~p"/#{subject.account.slug}"}}
    end
  end

  describe "on_mount: :redirect_if_user_is_authenticated" do
    setup context do
      socket = %Phoenix.LiveView.Socket{
        endpoint: Web.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{
          live_temp: %{},
          connect_info: %{
            user_agent: context.admin_subject.context.user_agent,
            peer_data: %{address: {100, 64, 100, 58}}
          }
        }
      }

      %{socket: socket}
    end

    test "redirects if there is an authenticated user ", %{
      conn: conn,
      socket: socket,
      context: context,
      account: account,
      nonce: nonce,
      admin_encoded_fragment: encoded_fragment
    } do
      session =
        conn
        |> put_session(:sessions, [{context.type, account.id, nonce <> encoded_fragment}])
        |> get_session()

      params = %{"account_id_or_slug" => account.id}

      assert {:halt, updated_socket} =
               on_mount(:redirect_if_user_is_authenticated, params, session, socket)

      assert updated_socket.redirected == {:redirect, %{status: 302, to: ~p"/#{account}/sites"}}
    end

    test "doesn't redirect if there is no authenticated user", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session = get_session(conn)

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} =
               on_mount(:redirect_if_user_is_authenticated, params, session, socket)

      assert is_nil(updated_socket.redirected)
    end
  end
end
