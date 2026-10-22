defmodule PortalWeb.Plugs.FetchSubject do
  @behaviour Plug

  import Plug.Conn
  alias Portal.Account
  alias Portal.Authentication

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{account: %Account{} = account}} = conn, opts) do
    cookie = Keyword.get(opts, :cookie, PortalWeb.Cookie.Session)
    session_key = Keyword.get(opts, :session_key, :portal_session_id)

    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    context = Authentication.Context.build(remote_ip, user_agent, conn.req_headers, :portal)

    with %{session_id: session_id} <- cookie.fetch(conn, account.id),
         {:ok, session} <- Authentication.fetch_portal_session(account.id, session_id),
         {:ok, subject} <- Authentication.build_subject(session, context) do
      conn
      |> put_live_socket_id(session_key, session)
      |> put_session(session_key, session.id)
      |> assign(:subject, subject)
    else
      _ -> delete_account_session(conn, account, cookie, session_key)
    end
  end

  def call(conn, _opts), do: conn

  # Only the portal session owns this key. Writing it from the app-approval flow
  # would let a portal sign-out disconnect the wrong sockets, and is not needed
  # there because nothing force-disconnects that flow.
  defp put_live_socket_id(conn, :portal_session_id, session),
    do: put_session(conn, :live_socket_id, Portal.Sockets.socket_id(session.id))

  defp put_live_socket_id(conn, _session_key, _session), do: conn

  defp delete_account_session(conn, %Account{} = account, cookie, session_key) do
    conn
    # Cleared, not just left alone: this account has no session, so any subject
    # already on the conn belongs to a different one and must not survive into
    # EnsureAuthenticated.
    |> assign(:subject, nil)
    |> put_live_socket_id_deletion(session_key)
    |> delete_session(session_key)
    |> cookie.delete(account.id)
  end

  defp put_live_socket_id_deletion(conn, :portal_session_id),
    do: delete_session(conn, :live_socket_id)

  defp put_live_socket_id_deletion(conn, _session_key), do: conn
end
