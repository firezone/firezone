defmodule Web.PageComponents do
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents

  slot :title, required: true, doc: "The title of the section to be displayed"
  slot :action, required: false, doc: "A slot for action to the right from title"

  slot :content, required: true, doc: "A slot for content of the section" do
    attr :flash, :any, doc: "The flash to be displayed above the content"
  end

  def section(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-800 overflow-hidden border-solid border-slate-200 border-t">
      <.header>
        <:title>
          <%= render_slot(@title) %>
        </:title>

        <:actions :if={not Enum.empty?(@action)}>
          <%= for action <- @action do %>
            <%= render_slot(action) %>
          <% end %>
        </:actions>
      </.header>

      <section :for={content <- @content}>
        <div :if={Map.get(content, :flash)}>
          <.flash kind={:info} flash={Map.get(content, :flash)} style="wide" />
          <.flash kind={:error} flash={Map.get(content, :flash)} style="wide" />
        </div>
        <%= render_slot(content) %>
      </section>
    </div>
    """
  end

  def link_style do
    [
      "text-blue-600",
      "dark:text-blue-500",
      "hover:underline",
      "dark:hover:underline"
    ]
  end
end
