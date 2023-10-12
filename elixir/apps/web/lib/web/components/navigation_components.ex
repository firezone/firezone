defmodule Web.NavigationComponents do
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents

  attr :subject, :any, required: true

  def topbar(assigns) do
    ~H"""
    <nav class="bg-gray-50 dark:bg-gray-600 border-b border-gray-200 px-4 py-2.5 dark:border-gray-700 fixed left-0 right-0 top-0 z-50">
      <div class="flex flex-wrap justify-between items-center">
        <div class="flex justify-start items-center">
          <button
            data-drawer-target="drawer-navigation"
            data-drawer-toggle="drawer-navigation"
            aria-controls="drawer-navigation"
            class={[
              "p-2 mr-2 text-gray-600 rounded-lg cursor-pointer md:hidden",
              "hover:text-gray-900 hover:bg-gray-100",
              "focus:bg-gray-100 dark:focus:bg-gray-700 focus:ring-2 focus:ring-gray-100",
              "dark:focus:ring-gray-700 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white"
            ]}
          >
            <.icon name="hero-bars-3-center-left" class="w-6 h-6" />
            <span class="sr-only">Toggle sidebar</span>
          </button>
          <a
            href="https://www.firezone.dev/?utm_source=product"
            class="flex items-center justify-between mr-4"
          >
            <img src={~p"/images/logo.svg"} class="mr-3 h-8" alt="Firezone Logo" />
            <span class="self-center text-2xl font-semibold whitespace-nowrap dark:text-white">
              firezone
            </span>
          </a>
        </div>
        <div class="flex items-center lg:order-2">
          <.dropdown id="user-menu">
            <:button>
              <span class="sr-only">Open user menu</span>
              <.gravatar size={25} email={@subject.identity.provider_identifier} class="rounded-full" />
            </:button>
            <:dropdown>
              <.subject_dropdown subject={@subject} />
            </:dropdown>
          </.dropdown>
        </div>
      </div>
    </nav>
    """
  end

  attr :subject, :any, required: true

  def subject_dropdown(assigns) do
    ~H"""
    <div class="py-3 px-4">
      <span class="block text-sm font-semibold text-gray-900 dark:text-white">
        <%= @subject.actor.name %>
      </span>
      <span class="block text-sm text-gray-900 truncate dark:text-white">
        <%= @subject.identity.provider_identifier %>
      </span>
    </div>
    <ul class="py-1 text-gray-700 dark:text-gray-300" aria-labelledby="user-menu-dropdown">
      <li>
        <.link navigate={~p"/#{@subject.account}/actors/#{@subject.actor}"} class={~w[
          block py-2 px-4 text-sm hover:bg-gray-100
          dark:hover:bg-gray-600 dark:text-gray-400
          dark:hover:text-white]}>
          Profile
        </.link>
      </li>
    </ul>
    <ul class="py-1 text-gray-700 dark:text-gray-300" aria-labelledby="user-menu-dropdown">
      <li>
        <a
          href={~p"/#{@subject.account}/sign_out"}
          class="block py-2 px-4 text-sm hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
        >
          Sign out
        </a>
      </li>
    </ul>
    """
  end

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
      <div class="overflow-y-auto py-1 px-1 h-full bg-white dark:bg-gray-800">
        <ul>
          <%= render_slot(@inner_block) %>
        </ul>
      </div>
      <%= render_slot(@bottom) %>
    </aside>
    """
  end

  attr :id, :string, required: true, doc: "ID of the nav group container"
  slot :button, required: true
  slot :dropdown, required: true

  def dropdown(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "flex mx-3 text-sm bg-gray-800 rounded-full md:mr-0",
        "focus:ring-4 focus:ring-gray-300 dark:focus:ring-gray-600"
      ]}
      id={"#{@id}-button"}
      aria-expanded="false"
      data-dropdown-toggle={"#{@id}-dropdown"}
    >
      <%= render_slot(@button) %>
    </button>
    <div
      class={[
        "hidden",
        "z-50 my-4 w-56 text-base list-none bg-white rounded",
        "divide-y divide-gray-100 shadow",
        "dark:bg-gray-700 dark:divide-gray-600 rounded-xl"
      ]}
      id={"#{@id}-dropdown"}
    >
      <%= render_slot(@dropdown) %>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true
  attr :current_path, :string, required: true
  attr :active_class, :string, required: false, default: "dark:bg-gray-700 bg-gray-100"

  def sidebar_item(assigns) do
    ~H"""
    <li>
      <.link navigate={@navigate} class={~w[
      flex items-center p-2
      text-base font-medium text-gray-900
      rounded-lg
      #{String.starts_with?(@current_path, @navigate) && @active_class}
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
  attr :icon, :string, required: true
  attr :current_path, :string, required: true
  attr :active_class, :string, required: false, default: "dark:bg-gray-700 bg-gray-100"

  slot :name, required: true

  slot :item, required: true do
    attr :navigate, :string, required: true
  end

  def sidebar_item_group(assigns) do
    dropdown_hidden =
      !Enum.any?(assigns.item, fn item ->
        String.starts_with?(assigns.current_path, item.navigate)
      end)

    assigns = assign(assigns, dropdown_hidden: dropdown_hidden)

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
        aria-hidden={@dropdown_hidden}
      >
        <.icon name={@icon} class={~w[
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
      <ul id={"dropdown-#{@id}"} class={if @dropdown_hidden, do: "hidden", else: ""}>
        <li :for={item <- @item}>
          <.link navigate={item.navigate} class={~w[
              flex items-center p-2 pl-11 w-full group rounded-lg
              text-base font-medium text-gray-900
              #{String.starts_with?(@current_path, item.navigate) && @active_class}
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
  attr :account, :any,
    required: false,
    default: nil,
    doc: "Account assign which will be used to fetch the home path."

  slot :inner_block, required: true, doc: "Breadcrumb entries"

  def breadcrumbs(assigns) do
    ~H"""
    <nav class="py-3 px-4" class="flex" aria-label="Breadcrumb">
      <ol class="inline-flex items-center space-x-1 md:space-x-2">
        <li class="inline-flex items-center">
          <.link
            navigate={if @account, do: ~p"/#{@account}/actors", else: @home_path}
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
  attr :path, :string, default: nil, doc: "The path for the breadcrumb entry."

  def breadcrumb(assigns) do
    ~H"""
    <li class="inline-flex items-center">
      <div class="flex items-center text-gray-700 dark:text-gray-300">
        <.icon name="hero-chevron-right-solid" class="w-6 h-6" />
        <.link
          :if={not is_nil(@path)}
          navigate={@path}
          class="ml-1 text-sm font-medium text-gray-700 hover:text-gray-900 md:ml-2 dark:text-gray-300 dark:hover:text-white"
        >
          <%= render_slot(@inner_block) %>
        </.link>

        <span
          :if={is_nil(@path)}
          class="ml-1 text-sm font-medium text-gray-700 hover:text-gray-900 md:ml-2 dark:text-gray-300 dark:hover:text-white"
        >
          <%= render_slot(@inner_block) %>
        </span>
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
