defmodule Web.Auth do
  use Web, :verified_routes
  alias Domain.Auth

  def signed_in_path(%Auth.Subject{actor: %{type: :account_admin_user}} = subject),
    do: ~p"/#{subject.account}/dashboard"

  def put_subject_in_session(conn, %Auth.Subject{} = subject) do
    {:ok, session_token} = Domain.Auth.create_session_token_from_subject(subject)

    conn
    |> Plug.Conn.put_session(:signed_in_at, DateTime.utc_now())
    |> Plug.Conn.put_session(:session_token, session_token)
    |> Plug.Conn.put_session(:live_socket_id, "actors_sessions:#{subject.actor.id}")
  end

  @doc """
  This is a wrapper around `Domain.Auth.sign_in/5` that fails authentication and redirects
  to app install instructions for the users that should not have access to the control plane UI.
  """
  def sign_in(conn, provider, provider_identifier, secret) do
    case Domain.Auth.sign_in(
           provider,
           provider_identifier,
           secret,
           conn.assigns.user_agent,
           conn.remote_ip
         ) do
      {:ok, %Auth.Subject{actor: %{type: :account_admin_user}} = subject} ->
        {:ok, subject}

      {:ok, %Auth.Subject{}} ->
        {:error, :invalid_actor_type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sign_in(conn, provider, payload) do
    case Domain.Auth.sign_in(provider, payload, conn.assigns.user_agent, conn.remote_ip) do
      {:ok, %Auth.Subject{actor: %{type: :account_admin_user}} = subject} ->
        {:ok, subject}

      {:ok, %Auth.Subject{}} ->
        {:error, :invalid_actor_type}

      {:error, reason} ->
        {:error, reason}
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
  def fetch_subject(%Plug.Conn{} = conn, _opts) do
    with token when not is_nil(token) <- Plug.Conn.get_session(conn, :session_token),
         {:ok, subject} <-
           Domain.Auth.sign_in(token, conn.assigns.user_agent, conn.remote_ip),
         true <- conn.path_params["account_id"] == subject.account.id do
      Plug.Conn.assign(conn, :subject, subject)
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
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id"]}/sign_in")
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

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the subject:

      defmodule Web.PageLive do
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

  def on_mount(:ensure_authenticated, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns.subject do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/#{socket.assigns.account}/sign_in")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_account_admin_user_actor, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns.subject.actor.type == :account_admin_user do
      {:cont, socket}
    else
      raise Ecto.NoResultsError
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns.subject do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket.assigns.subject))}
    else
      {:cont, socket}
    end
  end

  defp mount_subject(socket, params, session) do
    Phoenix.Component.assign_new(socket, :subject, fn ->
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      remote_ip = Phoenix.LiveView.get_connect_info(socket, :peer_data).address

      with token when not is_nil(token) <- session["session_token"],
           {:ok, subject} <- Domain.Auth.sign_in(token, user_agent, remote_ip),
           true <- params["account_id"] == subject.account.id do
        subject
      else
        _ -> nil
      end
    end)
  end
end
