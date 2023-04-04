defmodule Web.ModalComponent do
  @moduledoc """
  Wraps a component in a modal.
  """
  use Web, :live_component

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
      phx-page-loading
    >
      <div class="modal-background"></div>
      <div class="modal-card">
        <header class="modal-card-head">
          <p class="modal-card-title"><%= @opts[:title] %></p>
          <button class="delete" aria-label="close" phx-click="close" phx-target={@myself}></button>
        </header>
        <section class="modal-card-body">
          <div class="block">
            <%= if is_atom(@component) do %>
              <.live_component module={@component} {@opts} />
            <% else %>
              <%= @component %>
            <% end %>
          </div>
        </section>
        <footer class="modal-card-foot is-justify-content-flex-end">
          <%= if !(assigns[:hide_footer_content] || @opts[:hide_footer_content]) do %>
            <%= Phoenix.View.render(Web.SharedView, "submit_button.html",
              button_text: @opts[:button_text],
              form: @opts[:form]
            ) %>
          <% end %>
        </footer>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("close", _, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.return_to)}
  end
end
