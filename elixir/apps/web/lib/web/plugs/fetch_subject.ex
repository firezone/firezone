defmodule Web.Plugs.FetchSubject do
  @behaviour Plug

  import Plug.Conn
  alias Domain.Account

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{account: %Account{} = account}} = conn, _opts) do
    context_type = context_type(conn.params)
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    context = Domain.Auth.Context.build(remote_ip, user_agent, conn.req_headers, context_type)

    with {:ok, token_id} <- Web.Session.Cookie.fetch_account_cookie(conn, account.id),
         {:ok, token} <- Domain.Auth.fetch_token(account.id, token_id, context_type),
         {:ok, subject} <- Domain.Auth.build_subject(token, context) do
      conn
      |> put_session(:live_socket_id, Domain.Auth.socket_id(token.id))
      # We re-fetch the token in the fetch_subject live hook
      |> put_session(:token_id, token.id)
      |> assign(:subject, subject)
    else
      error ->
        trace = Process.info(self(), :current_stacktrace)

        Logger.info("Failed to fetch subject",
          error: error,
          stacktrace: trace,
          account_id: account.id
        )

        conn
        |> delete_account_session(account)
    end
  end

  def call(conn, _opts), do: conn

  defp delete_account_session(conn, %Account{} = account) do
    conn
    |> delete_session(:live_socket_id)
    |> delete_session(:token_id)
    |> Web.Session.Cookie.delete_account_cookie(account.id)
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser
end
