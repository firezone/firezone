defmodule Web.Settings.IdentityProviders.Index do
  @moduledoc """
    A thin wrapper to dispatch to the legacy or new identity provider settings UI
    based on whether the account has migrated to the new authentication system.

    TODO: IDP REFACTOR
    This can be removed once all customers have migrated to the new authentication system.
  """

  use Web, :live_view

  @legacy_index Web.Settings.IdentityProviders.IndexLegacy
  @new_index Web.Settings.IdentityProviders.IndexNew

  def mount(params, session, socket) do
    migrated? = Domain.Migrator.migrated?(socket.assigns.account)
    impl = if migrated?, do: @new_index, else: @legacy_index

    socket = assign(socket, migrated?: migrated?, impl: impl)
    impl.mount(params, session, socket)
  end

  def handle_event(event, params, socket) do
    socket.assigns.impl.handle_event(event, params, socket)
  end

  def handle_info(msg, socket) do
    socket.assigns.impl.handle_info(msg, socket)
  end

  def render(assigns) do
    assigns.impl.render(assigns)
  end
end
