defmodule Web.Auth do
  use Web, :verified_routes
  alias Domain.Auth

  def signed_in_path(%Auth.Subject{actor: %{type: :account_admin_user}} = subject),
    do: ~p"/#{subject.account}/dashboard"

  def put_subject_in_session(conn, %Auth.Subject{} = subject) do
    {:ok, session_token} = Auth.create_session_token_from_subject(subject)

    conn
    |> Plug.Conn.put_session(:signed_in_at, DateTime.utc_now())
    |> Plug.Conn.put_session(:session_token, session_token)
    |> Plug.Conn.put_session(:live_socket_id, "actors_sessions:#{subject.actor.id}")
  end

  @doc """
  Redirects the signed in user depending on the actor type.

  The account admin users are sent to dashboard or a return path if it's stored in session.

  The account users are only expected to authenticate using client apps.
  If the platform is known, we direct them to the application through a deep link or an app link;
  if not, we guide them to the install instructions accompanied by an error message.
  """
  def signed_in_redirect(
        conn,
        %Auth.Subject{actor: %{type: :account_admin_user}} = subject,
        _client_platform,
        _client_csrf_token
      ) do
    redirect_to = Plug.Conn.get_session(conn, :user_return_to) || signed_in_path(subject)

    conn
    |> Web.Auth.renew_session()
    |> Web.Auth.put_subject_in_session(subject)
    |> Plug.Conn.delete_session(:user_return_to)
    |> Phoenix.Controller.redirect(to: redirect_to)
  end

  def signed_in_redirect(
        conn,
        %Auth.Subject{actor: %{type: :account_user}} = subject,
        client_platform,
        client_csrf_token
      ) do
    platform_redirect_urls =
      Domain.Config.fetch_env!(:web, __MODULE__)
      |> Keyword.fetch!(:platform_redirect_urls)

    if redirect_to = Map.get(platform_redirect_urls, client_platform) do
      {:ok, client_token} = Auth.create_session_token_from_subject(subject)

      query =
        %{
          client_auth_token: client_token,
          client_csrf_token: client_csrf_token
        }
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> URI.encode_query()

      conn
      |> Phoenix.Controller.redirect(external: "#{redirect_to}?#{query}")
    else
      conn
      |> Phoenix.Controller.put_flash(
        :info,
        "Please use a client application to access Firezone."
      )
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}/")
    end
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See `renew_session/1`.
  """
  def sign_out(%Plug.Conn{} = conn) do
    # token = Plug.Conn.get_session(conn, :session_token)
    # subject && Accounts.delete_user_session_token(subject)

    if live_socket_id = Plug.Conn.get_session(conn, :live_socket_id) do
      conn.private.phoenix_endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
  end

  @doc """
  This function renews the session ID and erases the whole
  session to avoid fixation attacks.
  """
  def renew_session(%Plug.Conn{} = conn) do
    preferred_locale = Plug.Conn.get_session(conn, :preferred_locale)

    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.clear_session()
    |> Plug.Conn.put_session(:preferred_locale, preferred_locale)
  end

  ###########################
  ## Plugs
  ###########################

  @doc """
  Fetches the user agent value from headers and assigns it the connection.
  """
  def fetch_user_agent(%Plug.Conn{} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] -> Plug.Conn.assign(conn, :user_agent, user_agent)
      _ -> conn
    end
  end

  @doc """
  Fetches the session token from the session and assigns the subject to the connection.
  """
  def fetch_subject_and_account(%Plug.Conn{} = conn, _opts) do
    with token when not is_nil(token) <- Plug.Conn.get_session(conn, :session_token),
         {:ok, subject} <-
           Domain.Auth.sign_in(token, conn.assigns.user_agent, conn.remote_ip),
         {:ok, account} <-
           Domain.Accounts.fetch_account_by_id_or_slug(
             conn.path_params["account_id_or_slug"],
             subject
           ) do
      conn
      |> Plug.Conn.assign(:account, account)
      |> Plug.Conn.assign(:subject, subject)
    else
      _ -> conn
    end
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:subject] do
      conn
      |> Phoenix.Controller.redirect(to: signed_in_path(conn.assigns.subject))
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:subject] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}/sign_in")
      |> Plug.Conn.halt()
    end
  end

  @doc """
  Used for routes that require the user to be authenticated as a specific kind of actor.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated_actor_type(%Plug.Conn{} = conn, type) do
    if not is_nil(conn.assigns[:subject]) and conn.assigns[:subject].actor.type == type do
      conn
    else
      conn
      |> Web.FallbackController.call({:error, :not_found})
      |> Plug.Conn.halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    Plug.Conn.put_session(conn, :user_return_to, Phoenix.Controller.current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  ###########################
  ## LiveView
  ###########################

  @doc """
  Handles mounting and authenticating the actor in LiveViews.

  Notice: every protected route should have `account_id` in the path params.

  ## `on_mount` arguments

    * `:mount_subject` - assigns user_agent and subject to the socket assigns based on
      session_token, or nil if there's no session_token or no matching user.

    * `:ensure_authenticated` - authenticates the user from the session,
      and assigns the subject to socket assigns based on session_token.
      Redirects to login page if there's no logged user.

    * `:redirect_if_user_is_authenticated` - authenticates the user from the session.
      Redirects to signed_in_path if there's a logged user.

    * `:mount_account` - takes `account_id` from path params and loads the given account
      into the socket assigns using the `subject` mounted via `:mount_subject`. This is useful
      because some actions can be performed by superadmin users on behalf of other accounts
      so we can't really rely on `subject.account` in a lot of places.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the subject:

      defmodule Web.Page do
        use Web, :live_view

        on_mount {Web.UserAuth, :mount_subject}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{Web.UserAuth, :ensure_authenticated}] do
        live "/:account_id/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_subject, params, session, socket) do
    {:cont, mount_subject(socket, params, session)}
  end

  def on_mount(:mount_account, params, session, socket) do
    {:cont, mount_account(socket, params, session)}
  end

  def on_mount(:ensure_authenticated, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/#{params["account_id_or_slug"]}/sign_in")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_account_admin_user_actor, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject].actor.type == :account_admin_user do
      {:cont, socket}
    else
      raise Web.LiveErrors.NotFoundError
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject] do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket.assigns[:subject]))}
    else
      {:cont, socket}
    end
  end

  defp mount_subject(socket, _params, session) do
    Phoenix.Component.assign_new(socket, :subject, fn ->
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      real_ip = real_ip(socket)

      with token when not is_nil(token) <- session["session_token"],
           {:ok, subject} <- Domain.Auth.sign_in(token, user_agent, real_ip) do
        subject
      else
        _ -> nil
      end
    end)
  end

  defp mount_account(
         %{assigns: %{subject: subject}} = socket,
         %{"account_id_or_slug" => account_id_or_slug},
         _session
       ) do
    Phoenix.Component.assign_new(socket, :account, fn ->
      with {:ok, account} <-
             Domain.Accounts.fetch_account_by_id_or_slug(account_id_or_slug, subject) do
        account
      else
        _ -> nil
      end
    end)
  end

  defp real_ip(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers)

    real_ip =
      if is_list(x_headers) and length(x_headers) > 0 do
        RemoteIp.from(x_headers, Web.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end
end
