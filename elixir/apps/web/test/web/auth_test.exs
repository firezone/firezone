defmodule Web.AuthTest do
  use Web.ConnCase, async: true
  import Web.Auth

  setup do
    account = Fixtures.Accounts.create_account()

    admin_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    admin_identity = Fixtures.Auth.create_identity(account: account, actor: admin_actor)
    admin_subject = Fixtures.Auth.create_subject(identity: admin_identity)

    user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    user_identity = Fixtures.Auth.create_identity(account: account, actor: user_actor)
    user_subject = Fixtures.Auth.create_subject(identity: user_identity)

    %{
      account: account,
      admin_actor: admin_actor,
      admin_identity: admin_identity,
      admin_subject: admin_subject,
      user_actor: user_actor,
      user_identity: user_identity,
      user_subject: user_subject
    }
  end

  describe "signed_in_path/1" do
    test "redirects to sites page after sign in as account admin", %{admin_subject: subject} do
      assert signed_in_path(subject) == ~p"/#{subject.account.slug}/sites"
    end
  end

  describe "put_subject_in_session/2" do
    test "persists token session", %{conn: conn, admin_subject: subject} do
      conn = put_subject_in_session(conn, subject)
      assert token = get_session(conn, "session_token")

      assert {:ok, _subject} = Domain.Auth.sign_in(token, subject.context)
    end

    test "persists sign in time in session", %{conn: conn, admin_subject: subject} do
      conn = put_subject_in_session(conn, subject)
      assert %DateTime{} = get_session(conn, "signed_in_at")
    end

    test "persists live socket id in session", %{conn: conn, admin_subject: subject} do
      conn = put_subject_in_session(conn, subject)
      assert get_session(conn, "live_socket_id") == "actors_sessions:#{subject.actor.id}"
    end
  end

  describe "signed_in_redirect/4" do
    test "redirects regular users to the platform url", %{conn: conn, user_subject: subject} do
      redirected_to = conn |> signed_in_redirect(subject, "apple", "foo") |> redirected_to()
      assert redirected_to =~ "firezone://handle_client_auth_callback"
      assert redirected_to =~ "client_csrf_token=foo"

      redirected_to = conn |> signed_in_redirect(subject, "android", "foo") |> redirected_to()
      assert redirected_to =~ "/handle_client_auth_callback?"
      assert redirected_to =~ "client_csrf_token=foo"
    end

    test "redirects regular users to sign in if platform url is missing", %{
      conn: init_conn,
      user_subject: subject
    } do
      conn = init_conn |> fetch_flash() |> signed_in_redirect(subject, "", nil)
      assert redirected_to(conn) == ~p"/#{subject.account.slug}"
      assert conn.assigns.flash["info"] == "Please use a client application to access Firezone."

      conn = init_conn |> fetch_flash() |> signed_in_redirect(subject, nil, "")
      assert redirected_to(conn) == ~p"/#{subject.account.slug}"
      assert conn.assigns.flash["info"] == "Please use a client application to access Firezone."
    end

    test "redirects admin user to the platform url", %{conn: conn, admin_subject: subject} do
      redirected_to = conn |> signed_in_redirect(subject, "apple", "foo") |> redirected_to()
      assert redirected_to =~ "firezone://handle_client_auth_callback?"
      assert redirected_to =~ "client_csrf_token=foo"

      redirected_to = conn |> signed_in_redirect(subject, "android", "foo") |> redirected_to()
      assert redirected_to =~ "/handle_client_auth_callback?"
      assert redirected_to =~ "client_auth_token="
      assert redirected_to =~ "client_csrf_token=foo"
      assert redirected_to =~ "actor_name=#{URI.encode_www_form(subject.actor.name)}"
      assert redirected_to =~ "account_name=#{subject.account.name}"
      assert redirected_to =~ "account_slug=#{subject.account.slug}"

      assert redirected_to =~
               "identity_provider_identifier=#{subject.identity.provider_identifier}"
    end

    test "redirects admin user to the post-login path if platform url is missing", %{
      conn: conn,
      admin_subject: subject
    } do
      redirected_to = conn |> signed_in_redirect(subject, "", nil) |> redirected_to()
      assert redirected_to == ~p"/#{subject.account}/sites"

      redirected_to = conn |> signed_in_redirect(subject, nil, "") |> redirected_to()
      assert redirected_to == ~p"/#{subject.account}/sites"
    end

    test "redirects users to sign in if subject account doesn't match path param", %{
      conn: conn,
      admin_subject: subject
    } do
      init_conn =
        %{conn | path_params: %{"account_id_or_slug" => "foo"}}
        |> put_session(:test, "test")

      conn = init_conn |> signed_in_redirect(subject, "apple", nil)
      assert redirected_to(conn) == ~p"/foo"
      refute get_session(conn, :test)

      conn = init_conn |> signed_in_redirect(subject, "android", "bar")
      assert redirected_to(conn) == ~p"/foo"
      refute get_session(conn, :test)

      conn = init_conn |> signed_in_redirect(subject, "", nil)
      assert redirected_to(conn) == ~p"/foo"
      refute get_session(conn, :test)

      conn = init_conn |> signed_in_redirect(subject, nil, "")
      assert redirected_to(conn) == ~p"/foo"
      refute get_session(conn, :test)
    end
  end

  describe "sign_out/1" do
    test "erases session, session cookie and redirects to sign in page", %{
      conn: conn,
      account: account,
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        conn
        |> assign(:account, account)
        |> put_session(:session_token, session_token)
        |> fetch_cookies()
        |> sign_out()

      refute get_session(conn, :session_token)
      refute get_session(conn, :live_socket_id)

      assert redirected_to(conn, 302) == ~p"/#{subject.account}"
    end

    test "redirects to the sign in page even on invalid account ids", %{
      conn: conn,
      admin_subject: subject
    } do
      account_slug = "foo"
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => account_slug}
        }
        |> put_session(:session_token, session_token)
        |> fetch_cookies()
        |> sign_out()

      refute get_session(conn, :session_token)
      refute get_session(conn, :live_socket_id)

      assert redirected_to(conn, 302) == ~p"/#{account_slug}"
    end

    test "keeps client_platform param during sign out", %{
      conn: conn,
      account: account
    } do
      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => account.slug},
            query_params: %{"client_platform" => "apple"}
        }
        |> sign_out()

      refute get_session(conn, :session_token)
      refute get_session(conn, :live_socket_id)

      assert redirected_to(conn, 302) == ~p"/#{account}?client_platform=apple"
    end

    test "erases session, session cookie and redirects to IdP sign out page", %{
      conn: conn,
      account: account
    } do
      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        conn
        |> assign(:account, account)
        |> put_session(:session_token, session_token)
        |> fetch_cookies()
        |> sign_out()

      refute get_session(conn, :session_token)
      refute get_session(conn, :live_socket_id)

      assert redirected_to(conn, 302) == ~p"/#{subject.account}"
    end

    test "keeps preferred_locale session value", %{account: account, conn: conn} do
      conn =
        conn
        |> assign(:account, account)
        |> put_session(:preferred_locale, "uk_UA")
        |> fetch_cookies()
        |> sign_out()

      assert get_session(conn, :preferred_locale) == "uk_UA"
    end

    test "broadcasts to the given live_socket_id", %{
      account: account,
      admin_subject: subject,
      conn: conn
    } do
      live_socket_id = "actors_sessions:#{subject.actor.id}"
      Web.Endpoint.subscribe(live_socket_id)

      conn
      |> assign(:account, account)
      |> put_private(:phoenix_endpoint, @endpoint)
      |> put_session(:live_socket_id, live_socket_id)
      |> sign_out()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
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

  describe "fetch_subject_and_account/2" do
    setup context do
      %{conn: assign(context.conn, :user_agent, context.admin_subject.context.user_agent)}
    end

    test "authenticates user from session", %{conn: conn, admin_subject: subject} do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:session_token, session_token)
        |> fetch_subject_and_account([])

      assert conn.assigns.subject.identity.id == subject.identity.id
      assert conn.assigns.subject.actor.id == subject.actor.id
      assert conn.assigns.account.id == subject.account.id
    end

    test "puts load balancer GeoIP headers to subject context", %{
      conn: conn,
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_req_header("x-geo-location-region", "Ukraine")
        |> put_req_header("x-geo-location-city", "Kyiv")
        |> put_req_header("x-geo-location-coordinates", "50.4333,30.5167")
        |> put_session(:session_token, session_token)
        |> fetch_subject_and_account([])

      assert conn.assigns.subject.context.remote_ip_location_region == "Ukraine"
      assert conn.assigns.subject.context.remote_ip_location_city == "Kyiv"
      assert conn.assigns.subject.context.remote_ip_location_lat == 50.4333
      assert conn.assigns.subject.context.remote_ip_location_lon == 30.5167
    end

    test "puts country coordinates to subject assign", %{
      conn: conn,
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_req_header("x-geo-location-region", "UA")
        |> delete_req_header("x-geo-location-city")
        |> delete_req_header("x-geo-location-coordinates")
        |> put_session(:session_token, session_token)
        |> fetch_subject_and_account([])

      assert conn.assigns.subject.context.remote_ip_location_region == "UA"
      assert conn.assigns.subject.context.remote_ip_location_city == nil
      assert conn.assigns.subject.context.remote_ip_location_lat == 49.0
      assert conn.assigns.subject.context.remote_ip_location_lon == 32.0
    end

    test "does not authenticate to an incorrect account", %{conn: conn, admin_subject: subject} do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id_or_slug" => Ecto.UUID.generate()},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:session_token, session_token)
        |> fetch_subject_and_account([])

      refute Map.has_key?(conn.assigns, :subject)
      refute Map.has_key?(conn.assigns, :account)
    end

    test "does not authenticate if data is missing", %{conn: conn} do
      conn = fetch_subject_and_account(conn, [])
      refute get_session(conn, :session_token)
      refute Map.has_key?(conn.assigns, :subject)
      refute Map.has_key?(conn.assigns, :account)
    end
  end

  describe "redirect_if_user_is_authenticated/2" do
    test "redirects if user is authenticated to the signed in path", %{
      conn: conn,
      admin_subject: subject
    } do
      conn =
        conn
        |> assign(:subject, subject)
        |> fetch_query_params()
        |> redirect_if_user_is_authenticated([])

      assert conn.halted
      assert redirected_to(conn) == signed_in_path(subject)
    end

    test "redirects clients to platform specific urls", %{conn: conn, admin_subject: subject} do
      conn =
        %{conn | query_params: %{"client_platform" => "apple"}}
        |> assign(:subject, subject)
        |> redirect_if_user_is_authenticated([])

      assert conn.halted
      assert redirected_to(conn) =~ "firezone://handle_client_auth_callback"
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
      assert redirected_to(conn) == ~p"/#{account.slug}"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> ensure_authenticated([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> ensure_authenticated([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> ensure_authenticated([])

      assert halted_conn.halted
      refute get_session(halted_conn, :user_return_to)
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

    test "assigns subject based on a valid session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)
      session = conn |> put_session(:session_token, session_token) |> get_session()
      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert updated_socket.assigns.subject.identity.id == subject.identity.id
      assert updated_socket.assigns.subject.context.user_agent == subject.context.user_agent
      assert updated_socket.assigns.subject.context.remote_ip == subject.context.remote_ip
    end

    test "puts load balancer GeoIP information to subject context", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)
      session = conn |> put_session(:session_token, session_token) |> get_session()
      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, socket} = on_mount(:mount_subject, params, session, socket)

      assert socket.assigns.subject.context.remote_ip_location_region == "UA"
      assert socket.assigns.subject.context.remote_ip_location_city == "Kyiv"
      assert socket.assigns.subject.context.remote_ip_location_lat == 50.4333
      assert socket.assigns.subject.context.remote_ip_location_lon == 30.5167
    end

    test "puts country coordinates to subject context", %{
      conn: conn,
      admin_subject: subject
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

      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)
      session = conn |> put_session(:session_token, session_token) |> get_session()
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
      session = conn |> put_session(:session_token, session_token) |> get_session()
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
      admin_subject: subject
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

      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)
      session = conn |> put_session(:session_token, session_token) |> get_session()
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
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)
      session = conn |> put_session(:session_token, session_token) |> get_session()
      params = %{"account_id_or_slug" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:ensure_authenticated, params, session, socket)

      assert updated_socket.assigns.subject.identity.id == subject.identity.id
      assert is_nil(updated_socket.redirected)
    end

    test "redirects to login page if there isn't a valid session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session_token = "invalid_token"
      session = conn |> put_session(:session_token, session_token) |> get_session()
      params = %{"account_id_or_slug" => subject.account.slug}

      assert {:halt, updated_socket} = on_mount(:ensure_authenticated, params, session, socket)

      assert is_nil(updated_socket.assigns.subject)

      assert updated_socket.redirected == {:redirect, %{to: ~p"/#{subject.account.slug}"}}
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

      assert updated_socket.redirected == {:redirect, %{to: ~p"/#{subject.account.slug}"}}
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
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      session =
        conn
        |> put_session(:session_token, session_token)
        |> get_session()

      params = %{"account_id_or_slug" => subject.account.id}

      assert {:halt, updated_socket} =
               on_mount(:redirect_if_user_is_authenticated, params, session, socket)

      assert updated_socket.redirected ==
               {:redirect, %{to: ~p"/#{subject.account.slug}/sites"}}
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
