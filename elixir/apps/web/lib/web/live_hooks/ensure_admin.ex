defmodule Web.LiveHooks.EnsureAdmin do
  alias Domain.Auth.Subject
  alias Domain.Actor

  def on_mount(
        :default,
        _params,
        _session,
        %{assigns: %{subject: %Subject{actor: %Actor{type: :account_admin_user}}}} = socket
      ) do
    {:cont, socket}
  end

  def on_mount(:default, _params, _session, _socket) do
    raise Web.LiveErrors.NotFoundError
  end
end
