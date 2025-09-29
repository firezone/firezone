defmodule Web.LiveHooks.RedirectIfAuthenticated do
  alias Domain.Accounts.Account
  alias Domain.Auth.Subject
  alias Web.Session.Redirector

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
