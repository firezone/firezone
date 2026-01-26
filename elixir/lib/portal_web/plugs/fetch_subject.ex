defmodule PortalWeb.Plugs.FetchSubject do
  @behaviour Plug

  import Plug.Conn
  alias Portal.Account
  alias Portal.Authentication

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{account: %Account{} = account}} = conn, _opts) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    context = Authentication.Context.build(remote_ip, user_agent, conn.req_headers, :portal)

    with %PortalWeb.Cookie.Session{session_id: session_id} <-
           PortalWeb.Cookie.Session.fetch(conn, account.id),
         {:ok, session} <- Authentication.fetch_portal_session(account.id, session_id),
         {:ok, subject} <- Authentication.build_subject(session, context) do
      conn
      |> put_session(:live_socket_id, Portal.Sockets.socket_id(session.id))
      |> put_session(:portal_session_id, session.id)
      |> assign(:subject, subject)
    else
      _ -> delete_account_session(conn, account)
    end
  end

  def call(conn, _opts), do: conn

  defp delete_account_session(conn, %Account{} = account) do
    conn
    |> delete_session(:live_socket_id)
    |> delete_session(:portal_session_id)
    |> PortalWeb.Cookie.Session.delete(account.id)
  end
end
