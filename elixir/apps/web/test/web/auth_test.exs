defmodule Web.AuthTest do
  use Web.ConnCase, async: true
  import Web.Auth
  alias Phoenix.LiveView
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  setup do
    account = AccountsFixtures.create_account()

    admin_actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
    admin_identity = AuthFixtures.create_identity(account: account, actor: admin_actor)
    admin_subject = AuthFixtures.create_subject(admin_identity)

    user_actor = ActorsFixtures.create_actor(type: :account_user, account: account)
    user_identity = AuthFixtures.create_identity(account: account, actor: user_actor)
    user_subject = AuthFixtures.create_subject(user_identity)

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
    test "redirects to dashboard after sign in as account admin", %{admin_subject: subject} do
      assert signed_in_path(subject) == ~p"/#{subject.account}/dashboard"
    end

    test "redirects to account landing after sign in as account user", %{user_subject: subject} do
      assert signed_in_path(subject) == ~p"/#{subject.account}"
    end
  end

  describe "put_subject_in_session/2" do
    test "persists token session", %{conn: conn, admin_subject: subject} do
      conn = put_subject_in_session(conn, subject)
      assert token = get_session(conn, "session_token")

      assert {:ok, _subject} =
               Domain.Auth.sign_in(token, subject.context.user_agent, subject.context.remote_ip)
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

  describe "sign_out/1" do
    test "erases session and cookies", %{conn: conn, admin_subject: subject} do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        conn
        |> put_session(:session_token, session_token)
        |> fetch_cookies()
        |> sign_out()

      refute get_session(conn, :session_token)
      refute get_session(conn, :live_socket_id)
    end

    test "keeps preferred_locale session value", %{conn: conn} do
      conn =
        conn
        |> put_session(:preferred_locale, "uk_UA")
        |> fetch_cookies()
        |> sign_out()

      assert get_session(conn, :preferred_locale) == "uk_UA"
    end

    test "broadcasts to the given live_socket_id", %{admin_subject: subject, conn: conn} do
      live_socket_id = "actors_sessions:#{subject.actor.id}"
      Web.Endpoint.subscribe(live_socket_id)

      conn
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

  describe "fetch_subject/2" do
    setup context do
      %{conn: assign(context.conn, :user_agent, context.admin_subject.context.user_agent)}
    end

    test "authenticates user from session", %{conn: conn, admin_subject: subject} do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id" => subject.account.id},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:session_token, session_token)
        |> fetch_subject([])

      assert conn.assigns.subject.identity.id == subject.identity.id
      assert conn.assigns.subject.actor.id == subject.actor.id
    end

    test "does not authenticate to an incorrect account", %{conn: conn, admin_subject: subject} do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

      conn =
        %{
          conn
          | path_params: %{"account_id" => Ecto.UUID.generate()},
            remote_ip: {100, 64, 100, 58}
        }
        |> put_session(:session_token, session_token)
        |> fetch_subject([])

      refute Map.has_key?(conn.assigns, :subject)
    end

    test "does not authenticate if data is missing", %{conn: conn} do
      conn = fetch_subject(conn, [])
      refute get_session(conn, :session_token)
      refute Map.has_key?(conn.assigns, :subject)
    end
  end

  describe "redirect_if_user_is_authenticated/2" do
    test "redirects if user is authenticated", %{conn: conn, user_subject: subject} do
      conn =
        conn
        |> assign(:subject, subject)
        |> redirect_if_user_is_authenticated([])

      assert conn.halted
      assert redirected_to(conn) == signed_in_path(subject)
    end

    test "does not redirect if user is not authenticated", %{conn: conn} do
      conn = redirect_if_user_is_authenticated(conn, [])
      refute conn.halted
      refute conn.status
    end
  end

  describe "ensure_authenticated/2" do
    setup context do
      %{conn: %{context.conn | path_params: %{"account_id" => context.account.id}}}
    end

    test "redirects if user is not authenticated", %{account: account, conn: conn} do
      conn =
        conn
        |> fetch_flash()
        |> ensure_authenticated([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/#{account}/sign_in"

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
      socket = %LiveView.Socket{
        private: %{
          connect_info: %{
            user_agent: context.admin_subject.context.user_agent,
            peer_data: %{address: {100, 64, 100, 58}}
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
      params = %{"account_id" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert updated_socket.assigns.subject.identity.id == subject.identity.id
    end

    test "assigns nil to subject assign if there isn't a valid session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session_token = "invalid_token"
      session = conn |> put_session(:session_token, session_token) |> get_session()
      params = %{"account_id" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert is_nil(updated_socket.assigns.subject)
    end

    test "assigns nil to subject assign if there isn't a session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session = conn |> get_session()
      params = %{"account_id" => subject.account.id}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert is_nil(updated_socket.assigns.subject)
    end

    test "assigns nil to subject assign if account_id doesn't match token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)
      session = conn |> put_session(:session_token, session_token) |> get_session()
      params = %{"account_id" => Ecto.UUID.generate()}

      assert {:cont, updated_socket} = on_mount(:mount_subject, params, session, socket)
      assert is_nil(updated_socket.assigns.subject)
    end
  end

  describe "on_mount: ensure_authenticated" do
    setup context do
      socket = %LiveView.Socket{
        endpoint: Web.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}, account: context.account},
        private: %{
          __temp__: %{},
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
      params = %{"account_id" => subject.account.id}

      assert {:cont, updated_socket} =
               on_mount(:ensure_authenticated, params, session, socket)

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
      params = %{}

      assert {:halt, updated_socket} =
               on_mount(:ensure_authenticated, params, session, socket)

      assert is_nil(updated_socket.assigns.subject)

      assert updated_socket.redirected == {:redirect, %{to: ~p"/#{subject.account}/sign_in"}}
    end

    test "redirects to login page if there isn't a session_token", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session = conn |> get_session()
      params = %{}

      assert {:halt, updated_socket} =
               on_mount(:ensure_authenticated, params, session, socket)

      assert is_nil(updated_socket.assigns.subject)

      assert updated_socket.redirected == {:redirect, %{to: ~p"/#{subject.account}/sign_in"}}
    end
  end

  describe "on_mount: :redirect_if_user_is_authenticated" do
    setup context do
      socket = %LiveView.Socket{
        endpoint: Web.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{
          __temp__: %{},
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

      params = %{"account_id" => subject.account.id}

      assert {:halt, updated_socket} =
               on_mount(:redirect_if_user_is_authenticated, params, session, socket)

      assert updated_socket.redirected == {:redirect, %{to: ~p"/#{subject.account}/dashboard"}}
    end

    test "doesn't redirect if there is no authenticated user", %{
      conn: conn,
      socket: socket,
      admin_subject: subject
    } do
      session = get_session(conn)

      params = %{"account_id" => subject.account.id}

      assert {:cont, updated_socket} =
               on_mount(:redirect_if_user_is_authenticated, params, session, socket)

      assert is_nil(updated_socket.redirected)
    end
  end
end
