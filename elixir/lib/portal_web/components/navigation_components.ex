defmodule PortalWeb.NavigationComponents do
  use Phoenix.Component
  use Web, :verified_routes
  import PortalWeb.CoreComponents

  attr :subject, :any, required: true

  def topbar(assigns) do
    ~H"""
    <nav class="bg-neutral-50 border-b border-neutral-200 px-4 py-2.5 fixed left-0 right-0 top-0 z-50">
      <div class="flex flex-wrap justify-between items-center">
        <div class="flex justify-start items-center">
          <button
            data-drawer-target="drawer-navigation"
            data-drawer-toggle="drawer-navigation"
            aria-controls="drawer-navigation"
            class={[
              "p-2 mr-2 text-neutral-600 rounded cursor-pointer lg:hidden",
              "hover:text-neutral-900 hover:bg-neutral-100"
            ]}
          >
            <.icon name="hero-bars-3-center-left" class="w-6 h-6" />
            <span class="sr-only">Toggle sidebar</span>
          </button>
          <a href={~p"/"} class="flex items-center justify-between mr-4">
            <img src={~p"/images/logo.svg"} class="mr-3 h-8" alt="Firezone Logo" />
            <span class="self-center text-2xl font-semibold tracking-tight whitespace-nowrap">
              Firezone
            </span>
          </a>
        </div>
        <div class="flex items-center lg:order-2">
          <a
            target="_blank"
            href="https://www.firezone.dev/kb?utm_source=product"
            class="mr-6 mt-1 text-neutral-700 hover:text-neutral-900 hover:underline lg:ml-2 hidden lg:block"
          >
            Docs
          </a>
          <a
            target="_blank"
            href="https://firezone.statuspage.io"
            class="mr-6 mt-1 text-neutral-700 hover:text-neutral-900 hover:underline lg:ml-2 hidden lg:block"
          >
            Status
          </a>

          <.dropdown id="user-menu">
            <:button>
              <span class="sr-only">Open user menu</span>
              <.avatar actor={@subject.actor} size={25} class="rounded-full" />
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
      <span class="block text-sm font-medium text-neutral-900">
        {@subject.actor.name}
      </span>
      <span class="block text-sm text-neutral-900 truncate">
        {@subject.actor.email}
      </span>
    </div>
    <ul class="py-1 text-neutral-700" aria-labelledby="user-menu-dropdown">
      <li>
        <.link navigate={~p"/#{@subject.account}/actors/#{@subject.actor}"} class={~w[
          block py-2 px-4 text-sm hover:bg-neutral-100
        ]}>
          Profile
        </.link>
      </li>
    </ul>
    <ul class="py-1 text-neutral-700" aria-labelledby="user-menu-dropdown">
      <li>
        <form action={~p"/#{@subject.account}/sign_out"} method="post">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button
            type="submit"
            class="block w-full text-left py-2 px-4 text-sm hover:bg-neutral-100"
          >
            Sign out
          </button>
        </form>
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
    <aside
      class={[
        "fixed top-0 left-0 z-40 lg:z-10",
        "w-64 h-screen",
        "pt-14 pb-8",
        "transition-transform -translate-x-full",
        "bg-white border-r border-neutral-200",
        "lg:translate-x-0"
      ]}
      aria-label="Sidenav"
      id="drawer-navigation"
    >
      <div class="overflow-y-auto py-1 px-2 h-full bg-white">
        <ul>
          {render_slot(@inner_block)}
        </ul>
      </div>
      {render_slot(@bottom)}
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
      class={["flex mx-3 text-sm bg-neutral-800 rounded-full md:mr-0"]}
      id={"#{@id}-button"}
      aria-expanded="false"
      data-dropdown-toggle={"#{@id}-dropdown"}
    >
      {render_slot(@button)}
    </button>
    <div
      class={[
        "hidden",
        "z-50 my-4 w-56 text-base list-none bg-white rounded",
        "divide-y divide-neutral-100 shadow",
        "rounded-xl"
      ]}
      id={"#{@id}-dropdown"}
    >
      {render_slot(@dropdown)}
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true
  attr :current_path, :string, required: true

  attr :active_class, :string,
    required: false,
    default: "bg-neutral-50 text-neutral-800 font-medium"

  def sidebar_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@navigate}
        data-drawer-hide="drawer-navigation"
        class={~w[
      flex items-center px-4 py-2
      text-base
      rounded
      #{sidebar_item_active?(@current_path, @navigate) && @active_class}
      text-neutral-700
      hover:bg-neutral-100 hover:text-neutral-900
      ]}
      >
        <.icon name={@icon} class={~w[
          w-5 h-5
        ]} />
        <span class="ml-3 text-lg">{render_slot(@inner_block)}</span>
      </.link>
    </li>
    """
  end

  defp sidebar_item_active?(current_path, destination_path) do
    [_, _slug_or_id, current_subpath] = String.split(current_path, "/", parts: 3)
    [_, _slug_or_id, destination_subpath] = String.split(destination_path, "/", parts: 3)
    String.starts_with?(current_subpath, destination_subpath)
  end

  attr :id, :string, required: true, doc: "ID of the nav group container"
  attr :icon, :string, required: true
  attr :current_path, :string, required: true

  attr :active_class, :string,
    required: false,
    default: "bg-neutral-50 text-neutral-800 font-medium"

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
          flex items-center px-4 py-2 w-full rounded
          text-lg text-neutral-700
          transition duration-75
          hover:bg-neutral-100 hover:text-neutral-900]}
        aria-controls={"dropdown-#{@id}"}
        data-collapse-toggle={"dropdown-#{@id}"}
        aria-hidden={@dropdown_hidden}
      >
        <.icon name={@icon} class={~w[
          w-5 h-5 text-neutral-700]} />
        <span class="flex-1 ml-3 text-left whitespace-nowrap">{render_slot(@name)}</span>
        <.icon name="hero-chevron-down-solid" class={~w[
          w-5 h-5 text-neutral-700]} />
      </button>
      <ul id={"dropdown-#{@id}"} class={if @dropdown_hidden, do: "hidden", else: ""}>
        <li :for={item <- @item}>
          <.link
            navigate={item.navigate}
            data-drawer-hide="drawer-navigation"
            class={~w[
              flex items-center p-2 pl-12 w-full group rounded
              text-lg text-neutral-700
              #{String.starts_with?(@current_path, item.navigate) && @active_class}
              hover:text-neutral-900
              hover:bg-neutral-100]}
          >
            {render_slot(item)}
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
            navigate={if @account, do: ~p"/#{@account}/sites", else: @home_path}
            class="inline-flex items-center text-neutral-700 hover:text-neutral-900"
          >
            <.icon name="hero-home-solid" class="w-3.5 h-3.5 mr-2" /> Home
          </.link>

          {render_slot(@inner_block)}
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
      <div class="flex items-center text-neutral-700">
        <.icon name="hero-chevron-right-solid" class="w-3.5 h-3.5" />
        <.link
          :if={not is_nil(@path)}
          navigate={@path}
          class="ml-1 text-neutral-700 hover:text-neutral-900 md:ml-2"
        >
          {render_slot(@inner_block)}
        </.link>

        <span :if={is_nil(@path)} class="ml-1 text-sm text-neutral-700 hover:text-neutral-900 md:ml-2">
          {render_slot(@inner_block)}
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
        class="text-sm font-semibold leading-6 text-neutral-900 hover:text-neutral-700"
      >
        <.icon name="hero-arrow-left-solid" class="h-3 w-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders links based off our website path.

  ## Examples

    <.website_link path="/pricing>Pricing</.website_link>
    <.website_link path="/kb/deploy/gateways" class="text-neutral-900">Deploy Gateway(s)</.website_link>
    <.website_link path="/contact/sales">Contact Sales</.website_link>
  """
  attr :path, :string, required: true
  attr :fragment, :string, required: false, default: ""
  slot :inner_block, required: true
  attr :rest, :global

  def website_link(assigns) do
    ~H"""
    <.link
      href={"https://www.firezone.dev#{@path}?utm_source=product##{@fragment}"}
      class={link_style()}
      target="_blank"
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders links to the docs based off documentation portal path.

  ## Examples

    <.docs_action path="/kb/deploy/gateways" class="text-neutral-900">Deploy Gateway(s)</.docs_action>
  """
  attr :path, :string, required: true
  attr :fragment, :string, required: false, default: ""
  attr :rest, :global

  def docs_action(assigns) do
    ~H"""
    <.link
      title="View documentation for this page"
      href={"https://www.firezone.dev/kb#{@path}?utm_source=product##{@fragment}"}
      target="_blank"
      {@rest}
    >
      <.icon name="hero-question-mark-circle" class="mr-2 w-5 h-5" />
    </.link>
    """
  end
end
