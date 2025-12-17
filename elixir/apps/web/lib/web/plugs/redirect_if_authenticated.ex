defmodule Web.Plugs.RedirectIfAuthenticated do
  @moduledoc """
  Redirects authenticated users to the portal when accessing sign-in pages.

  When `as=client` is specified in the params, this plug does NOT redirect,
  allowing client sign-in flows to proceed even when a portal session exists.
  """
  @behaviour Plug

  alias Domain.Account
  alias Domain.Auth.Subject
  alias Web.Session.Redirector

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          params: %{"as" => "client"},
          assigns: %{account: %Account{}, subject: %Subject{}}
        } = conn,
        _opts
      ) do
    # Client sign-in flow should proceed even if user has a portal session
    conn
  end

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
