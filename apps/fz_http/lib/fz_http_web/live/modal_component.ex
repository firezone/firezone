defmodule FzHttpWeb.ModalComponent do
  @moduledoc """
  Wraps a component in a modal.
  """
  use FzHttpWeb, :live_component

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div
      id={@myself}
      class="modal is-active"
      phx-capture-click="close"
      phx-window-keydown="close"
      phx-key="escape"
      phx-target={@myself}
      phx-page-loading>
      <div class="modal-background"></div>
      <div class="modal-card">
        <header class="modal-card-head">
          <p class="modal-card-title"><%= @opts[:title] %></p>
          <button class="delete" aria-label="close" phx-click="close" phx-target={@myself}></button>
        </header>
        <section class="modal-card-body">
          <div class="block">
            <%= live_component(@component, @opts) %>
          </div>
        </section>
        <footer class="modal-card-foot">
        </footer>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("close", _, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.return_to)}
  end

  @impl Phoenix.LiveComponent
  @doc """
  XXX: This is needed due to a bug on pages with dropdowns.
  Basically this modal receives the phx-click-away event and the
  server crashes if this is not implemented.
  """
  def handle_event("close_dropdown", _params, socket) do
    {:noreply, socket}
  end
end
