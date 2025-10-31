defmodule Web.Plugs.FetchSubject do
  @behaviour Plug

  import Plug.Conn
  alias Domain.Accounts.Account
  alias Domain.Tokens

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{account: %Account{} = account}} = conn, _opts) do
    context_type = context_type(conn.params)
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip
    context = Domain.Auth.Context.build(remote_ip, user_agent, conn.req_headers, context_type)

    with {:ok, fragment} <- fetch_token(conn, account),
         {:ok, subject} <- Domain.Auth.authenticate(fragment, context) do
      conn
      |> put_session(:live_socket_id, Tokens.socket_id(subject.token_id))
      |> put_session(:token, fragment)
      |> assign(:subject, subject)
    else
      {:error, :unauthorized} ->
        delete_session(conn, account, migrated: Domain.Migrator.migrated?(account))

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp fetch_token(conn, account) do
    if Domain.Migrator.migrated?(account) do
      case Web.Session.Cookie.fetch_account_cookie(conn, account.id) do
        {:ok, token} -> {:ok, token}
        _ -> {:error, :unauthorized}
      end
    else
      sessions = get_session(conn, :sessions, [])
      Web.Auth.fetch_token(sessions, account.id)
    end
  end

  defp delete_session(conn, %Account{} = account, migrated: true) do
    conn
    |> delete_session(:live_socket_id)
    |> delete_session(:token)
    |> Web.Session.Cookie.delete_account_cookie(account.id)
  end

  # TODO: IDP REFACTOR
  # can be removed once all accounts are migrated
  defp delete_session(conn, %Account{} = account, migrated: false) do
    Web.Auth.delete_account_session(conn, account.id)
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser
end
