defmodule Web.NavigationComponents do
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents

  slot :bottom, required: false

  slot :inner_block,
    required: true,
    doc: "The items for the navigation bar should use `sidebar_item` component."

  def sidebar(assigns) do
    ~H"""
    <aside class={~w[
        fixed top-0 left-0 z-40
        w-64 h-screen
        pt-14 pb-8
        transition-transform -translate-x-full
        bg-white border-r border-gray-200
        md:translate-x-0
        dark:bg-gray-800 dark:border-gray-700]} aria-label="Sidenav" id="drawer-navigation">
      <div class="overflow-y-auto py-5 px-3 h-full bg-white dark:bg-gray-800">
        <ul class="space-y-2">
          <%= render_slot(@inner_block) %>
        </ul>
      </div>
      <%= render_slot(@bottom) %>
    </aside>
    """
  end

  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def sidebar_item(assigns) do
    ~H"""
    <li>
      <.link navigate={@navigate} class={~w[
      flex items-center p-2
      text-base font-medium text-gray-900
      rounded-lg
      hover:bg-gray-100
      dark:text-white dark:hover:bg-gray-700 group]}>
        <.icon name={@icon} class={~w[
        w-6 h-6
        text-gray-500
        transition duration-75
        group-hover:text-gray-900
        dark:text-gray-400 dark:group-hover:text-white]} />
        <span class="ml-3"><%= render_slot(@inner_block) %></span>
      </.link>
    </li>
    """
  end

  attr :id, :string, required: true, doc: "ID of the nav group container"
  # attr :icon, :string, required: true
  # attr :navigate, :string, required: true

  slot :name, required: true

  slot :item, required: true do
    attr :navigate, :string, required: true
  end

  def sidebar_item_group(assigns) do
    ~H"""
    <li>
      <button
        type="button"
        class={~w[
          flex items-center p-2 w-full group rounded-lg
          text-base font-medium text-gray-900
          transition duration-75
          hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700]}
        aria-controls={"dropdown-#{@id}"}
        data-collapse-toggle={"dropdown-#{@id}"}
      >
        <.icon name="hero-user-group-solid" class={~w[
          w-6 h-6 text-gray-500
          transition duration-75
          group-hover:text-gray-900
          dark:text-gray-400 dark:group-hover:text-white]} />
        <span class="flex-1 ml-3 text-left whitespace-nowrap"><%= render_slot(@name) %></span>
        <.icon name="hero-chevron-down-solid" class={~w[
          w-6 h-6 text-gray-500
          transition duration-75
          group-hover:text-gray-900
          dark:text-gray-400 dark:group-hover:text-white]} />
      </button>
      <ul id={"dropdown-#{@id}"} class="py-2 space-y-2">
        <li :for={item <- @item}>
          <.link navigate={item.navigate} class={~w[
              flex items-center p-2 pl-11 w-full group rounded-lg
              text-base font-medium text-gray-900
              transition duration-75
              hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700]}>
            <%= render_slot(item) %>
          </.link>
        </li>
      </ul>
    </li>
    """
  end

  @doc """
  Renders breadcrumbs section, for elements `<.breadcrumb />` component should be used.
  """
  attr :home_path, :string, required: true, doc: "The path for to the home page for a user."
  slot :inner_block, required: true, doc: "Breadcrumb entries"

  def breadcrumbs(assigns) do
    ~H"""
    <nav class="p-4 pb-0" class="flex" aria-label="Breadcrumb">
      <ol class="inline-flex items-center space-x-1 md:space-x-2">
        <li class="inline-flex items-center">
          <.link
            navigate={@home_path}
            class="inline-flex items-center text-gray-700 hover:text-gray-900 dark:text-gray-300 dark:hover:text-white"
          >
            <.icon name="hero-home-solid" class="w-4 h-4 mr-2" /> Home
          </.link>

          <%= render_slot(@inner_block) %>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  Renders a single breadcrumb entry. should be wrapped in <.breadcrumbs> component.
  """
  slot :inner_block, required: true, doc: "The label for the breadcrumb entry."
  attr :path, :string, required: true, doc: "The path for the breadcrumb entry."

  def breadcrumb(assigns) do
    ~H"""
    <li class="inline-flex items-center">
      <div class="flex items-center text-gray-700 dark:text-gray-300">
        <.icon name="hero-chevron-right-solid" class="w-6 h-6" />
        <.link
          navigate={@path}
          class="ml-1 text-sm font-medium text-gray-700 hover:text-gray-900 md:ml-2 dark:text-gray-300 dark:hover:text-white"
        >
          <%= render_slot(@inner_block) %>
        </.link>
      </div>
    </li>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back navigate={~p"/posts"}>Back to posts</.back>
  """
  attr :navigate, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link
        navigate={@navigate}
        class="text-sm font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
      >
        <.icon name="hero-arrow-left-solid" class="h-3 w-3" />
        <%= render_slot(@inner_block) %>
      </.link>
    </div>
    """
  end
end
