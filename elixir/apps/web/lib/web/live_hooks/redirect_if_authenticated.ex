defmodule Web.LiveHooks.RedirectIfAuthenticated do
  @moduledoc """
  Redirects authenticated users to the portal when accessing sign-in pages.

  When `as=client` is specified in the params, this hook does NOT redirect,
  allowing client sign-in flows to proceed even when a portal session exists.
  """
  alias Domain.Account
  alias Domain.Auth.Subject
  alias Web.Session.Redirector

  def on_mount(
        :default,
        %{"as" => "client"},
        _session,
        %{assigns: %{account: %Account{}, subject: %Subject{}}} = socket
      ) do
    # Client sign-in flow should proceed even if user has a portal session
    {:cont, socket}
  end

  def on_mount(
        :default,
        params,
        _session,
        %{assigns: %{account: %Account{} = account, subject: %Subject{}}} = socket
      ) do
    {:halt, Redirector.portal_signed_in(socket, account, params)}
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end
end
