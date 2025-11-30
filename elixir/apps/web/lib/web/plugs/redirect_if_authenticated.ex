defmodule Web.Plugs.RedirectIfAuthenticated do
  @behaviour Plug

  alias Domain.Account
  alias Domain.Auth.Subject
  alias Web.Session.Redirector

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          assigns: %{account: %Account{} = account, subject: %Subject{}}
        } = conn,
        _opts
      ) do
    conn
    |> Redirector.portal_signed_in(account, conn.params)
    |> Plug.Conn.halt()
  end

  def call(conn, _opts), do: conn
end
