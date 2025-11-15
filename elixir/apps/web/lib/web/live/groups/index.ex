defmodule Web.Groups.Index do
  use Web, :live_view

  def mount(params, session, socket) do
    account = socket.assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Groups.mount(params, session, socket)
    else
      Web.Groups.IndexLegacy.mount(params, session, socket)
    end
  end

  def handle_params(params, uri, socket) do
    account = socket.assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Groups.handle_params(params, uri, socket)
    else
      Web.Groups.IndexLegacy.handle_params(params, uri, socket)
    end
  end

  def handle_event(event, params, socket) do
    account = socket.assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Groups.handle_event(event, params, socket)
    else
      Web.Groups.IndexLegacy.handle_event(event, params, socket)
    end
  end

  def render(assigns) do
    account = assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Groups.render(assigns)
    else
      Web.Groups.IndexLegacy.render(assigns)
    end
  end
end
