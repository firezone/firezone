defmodule PortalWeb.Plugs.RedirectIfAuthenticated do
  @moduledoc """
  Redirects authenticated users to the portal when accessing sign-in pages.

  When `as=gui-client`, `as=headless-client`, or `as=client` (deprecated) is specified in the params,
  this plug does NOT redirect, allowing client sign-in flows to proceed even when a portal session exists.
  """
  @behaviour Plug

  alias Portal.Account
  alias Portal.Auth.Subject
  alias PortalWeb.Session.Redirector

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          params: %{"as" => as},
          assigns: %{account: %Account{}, subject: %Subject{}}
        } = conn,
        _opts
      )
      when as in ["client", "gui-client", "headless-client"] do
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
