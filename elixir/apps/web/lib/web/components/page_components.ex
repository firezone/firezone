defmodule Web.PageComponents do
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents

  slot :title, required: true, doc: "The title of the page to be displayed"

  slot :action, required: false, doc: "A slot for action to the right from title" do
    attr :type, :string
    attr :navigate, :string
    attr :icon, :string
  end

  slot :content, required: true, doc: "A slot for content which lists the entries" do
    attr :flash, :any, doc: "The flash to be displayed above the content"
  end

  slot :danger_zone,
    required: false,
    doc: "A slot for dangerous actions to be displayed below the content"

  def page(assigns) do
    ~H"""
    <.header>
      <:title>
        <%= render_slot(@title) %>
      </:title>

      <:actions :if={not Enum.empty?(@action)}>
        <.action_button
          :for={action <- @action}
          type={Map.get(action, :type)}
          navigate={action.navigate}
          icon={action.icon}
        >
          <%= render_slot(action) %>
        </.action_button>
      </:actions>
    </.header>

    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <section :for={content <- @content}>
        <div :if={Map.get(content, :flash)}>
          <.flash kind={:info} flash={Map.get(content, :flash)} style="wide" />
          <.flash kind={:error} flash={Map.get(content, :flash)} style="wide" />
        </div>

        <%= render_slot(content) %>
      </section>

      <section :if={not Enum.empty?(@danger_zone)}>
        <.header>
          <:title>
            Danger zone
          </:title>
          <:actions>
            <%= render_slot(@danger_zone) %>
          </:actions>
        </.header>
      </section>
    </div>
    """
  end

  attr :navigate, :string,
    required: false,
    doc: """
    The path to navigate to, when set an <a> tag will be used,
    otherwise a <button> tag will be used
    """

  attr :type, :string, default: nil, doc: "The style of the button"
  attr :icon, :string, required: true, doc: "The icon to be displayed on the button"
  attr :rest, :global
  slot :inner_block, required: true, doc: "The label for the button"

  def action_button(%{navigate: _} = assigns) do
    ~H"""
    <.link class={button_style(@type)} navigate={@navigate} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5 mr-2" />
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  def action_button(assigns) do
    ~H"""
    <button type="button" class={button_style(@type)} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5 mr-2" />
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  defp button_style do
    [
      "flex items-center justify-center",
      "px-4 py-2 rounded-lg",
      "font-medium text-sm",
      "focus:ring-4 focus:outline-none",
      "phx-submit-loading:opacity-75"
    ]
  end

  defp button_style("danger") do
    button_style() ++
      [
        "text-red-600",
        "border border-red-600",
        "hover:text-white hover:bg-red-600 focus:ring-red-300",
        "dark:border-red-500 dark:text-red-500 dark:hover:text-white dark:hover:bg-red-600 dark:focus:ring-red-900"
      ]
  end

  defp button_style(_style) do
    button_style() ++
      [
        "text-white",
        "bg-primary-500",
        "hover:bg-primary-600",
        "focus:ring-primary-300",
        "dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800"
      ]
  end
end
