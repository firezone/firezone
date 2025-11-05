defmodule Web.Actors.Index do
  use Web, :live_view

  def mount(params, session, socket) do
    account = socket.assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Actors.mount(params, session, socket)
    else
      Web.Actors.IndexLegacy.mount(params, session, socket)
    end
  end

  def handle_params(params, uri, socket) do
    account = socket.assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Actors.handle_params(params, uri, socket)
    else
      Web.Actors.IndexLegacy.handle_params(params, uri, socket)
    end
  end

  def handle_event(event, params, socket) do
    account = socket.assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Actors.handle_event(event, params, socket)
    else
      Web.Actors.IndexLegacy.handle_event(event, params, socket)
    end
  end

  def render(assigns) do
    account = assigns.subject.account

    if Domain.Migrator.migrated?(account) do
      Web.Actors.render(assigns)
    else
      Web.Actors.IndexLegacy.render(assigns)
    end
  end
end
