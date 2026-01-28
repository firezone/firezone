defmodule PortalWeb.LiveHooks.EnsureAdmin do
  alias Portal.Authentication.Subject
  alias Portal.Actor

  def on_mount(
        :default,
        _params,
        _session,
        %{assigns: %{subject: %Subject{actor: %Actor{type: :account_admin_user}}}} = socket
      ) do
    {:cont, socket}
  end

  def on_mount(:default, _params, _session, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end
end
