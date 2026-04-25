defmodule PortalWeb.NavigationComponents do
  use Phoenix.Component
  use PortalWeb, :verified_routes
  import PortalWeb.CoreComponents

  @doc """
  Renders the top navigation bar.
  """
  attr :subject, :any, required: true

  def topbar(assigns) do
    ~H"""
    <header class="flex items-center justify-between h-14 px-6 border-b border-[var(--border)] bg-[var(--surface)] shrink-0 z-20">
      <div class="flex items-center gap-2 text-sm text-[var(--text-secondary)]"></div>
      <div class="flex items-center gap-3">
        <a
          target="_blank"
          href="https://www.firezone.dev/kb?utm_source=product"
          class="text-sm text-[var(--text-secondary)] hover:text-[var(--text-primary)] hidden md:block"
        >
          Docs
        </a>
        <a
          target="_blank"
          href="https://firezone.statuspage.io"
          class="text-sm text-[var(--text-secondary)] hover:text-[var(--text-primary)] hidden md:block"
        >
          Status
        </a>
        <div id="theme-toggle" phx-hook="ThemeToggle" class="relative">
          <button
            type="button"
            id="theme-toggle-button"
            data-dropdown-toggle="theme-dropdown"
            data-dropdown-placement="bottom-end"
            class="p-2 rounded text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            aria-label="Change theme"
            aria-haspopup="true"
          >
            <.icon name="ri-sun-line" class="theme-icon-light w-4 h-4" />
            <.icon name="ri-moon-line" class="theme-icon-dark w-4 h-4" />
            <.icon name="ri-computer-line" class="theme-icon-system w-4 h-4" />
          </button>
          <div
            id="theme-dropdown"
            class="hidden z-50 w-36 text-sm bg-[var(--surface-overlay)] rounded shadow-sm border border-[var(--border)]"
          >
            <ul class="py-1" role="listbox" aria-label="Theme">
              <li>
                <button
                  type="button"
                  role="option"
                  data-theme-option="system"
                  class="flex items-center gap-2 w-full px-3 py-2 text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="ri-computer-line" class="w-4 h-4 shrink-0" />
                  <span>System</span>
                  <.icon name="ri-check-line" class="theme-check-system w-3 h-3 ml-auto shrink-0" />
                </button>
              </li>
              <li>
                <button
                  type="button"
                  role="option"
                  data-theme-option="light"
                  class="flex items-center gap-2 w-full px-3 py-2 text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="ri-sun-line" class="w-4 h-4 shrink-0" />
                  <span>Light</span>
                  <.icon name="ri-check-line" class="theme-check-light w-3 h-3 ml-auto shrink-0" />
                </button>
              </li>
              <li>
                <button
                  type="button"
                  role="option"
                  data-theme-option="dark"
                  class="flex items-center gap-2 w-full px-3 py-2 text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="ri-moon-line" class="w-4 h-4 shrink-0" />
                  <span>Dark</span>
                  <.icon name="ri-check-line" class="theme-check-dark w-3 h-3 ml-auto shrink-0" />
                </button>
              </li>
            </ul>
          </div>
        </div>
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
    </header>
    """
  end

  @doc """
  Renders the user dropdown contents.
  """
  attr :subject, :any, required: true

  def subject_dropdown(assigns) do
    ~H"""
    <div class="py-3 px-4">
      <span class="block text-sm font-medium text-[var(--text-primary)]">
        {@subject.actor.name}
      </span>
      <span class="block text-sm text-[var(--text-secondary)] truncate">
        {@subject.actor.email}
      </span>
    </div>
    <ul class="py-1 text-[var(--text-secondary)]" aria-labelledby="user-menu-dropdown">
      <li>
        <.link
          navigate={~p"/#{@subject.account}/settings/profile"}
          class="block py-2 px-4 text-sm hover:bg-[var(--surface-raised)] hover:text-[var(--text-primary)]"
        >
          Profile
        </.link>
      </li>
    </ul>
    <ul class="py-1 text-[var(--text-secondary)]" aria-labelledby="user-menu-dropdown">
      <li>
        <form action={~p"/#{@subject.account}/sign_out"} method="post">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button
            type="submit"
            class="block w-full text-left py-2 px-4 text-sm hover:bg-[var(--surface-raised)] hover:text-[var(--text-primary)]"
          >
            Sign out
          </button>
        </form>
      </li>
    </ul>
    """
  end

  @doc """
  Renders the collapsible sidebar with grouped navigation.
  """
  attr :account, :any, required: true
  attr :current_path, :string, required: true
  attr :subject, :any, required: true

  def sidebar(assigns) do
    ~H"""
    <aside
      id="sidebar"
      class="flex flex-col shrink-0 border-r border-[var(--border)] bg-[var(--surface)] overflow-hidden transition-[width] duration-200 ease-in-out w-56 z-20"
    >
      <%!-- Wordmark --%>
      <div
        data-sidebar-wordmark
        class="flex items-center h-14 px-3 border-b border-[var(--border)] shrink-0"
      >
        <a
          href={PortalWeb.Session.Redirector.default_portal_path(@account, @subject.actor)}
          class="flex items-center gap-2.5 min-w-0"
        >
          <img src={~p"/images/logo.svg"} class="h-6 w-6 shrink-0" alt="Firezone Logo" />
          <span
            data-sidebar-label
            class="font-semibold text-[var(--text-primary)] whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
          >
            Firezone
          </span>
        </a>
        <span
          :if={@subject.actor.type == :account_admin_user}
          data-sidebar-label
          class="ml-2 shrink-0 text-[9px] font-bold tracking-wider uppercase px-1.5 py-0.5 rounded bg-[var(--brand-muted)] text-[var(--brand)] transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
        >
          ADMIN
        </span>
      </div>

      <%!-- Navigation groups --%>
      <nav class="flex-1 overflow-y-auto py-3 px-2 space-y-4">
        <%!-- Access Control --%>
        <div>
          <p
            data-sidebar-group-label
            class="px-2 mb-1 text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]"
          >
            Access Control
          </p>
          <ul class="space-y-0.5">
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/resources"}
              icon="ri-server-line"
            >
              Resources
            </.sidebar_item>
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/groups"}
              icon="ri-team-line"
            >
              Groups
            </.sidebar_item>
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/policies"}
              icon="ri-shield-line"
            >
              Policies
            </.sidebar_item>
          </ul>
        </div>

        <%!-- Infrastructure --%>
        <div>
          <p
            data-sidebar-group-label
            class="px-2 mb-1 text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]"
          >
            Infrastructure
          </p>
          <ul class="space-y-0.5">
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/sites"}
              icon="ri-map-pin-line"
            >
              Sites
            </.sidebar_item>
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/clients"}
              icon="ri-computer-line"
            >
              Clients
            </.sidebar_item>
          </ul>
        </div>

        <%!-- Actors --%>
        <div>
          <p
            data-sidebar-group-label
            class="px-2 mb-1 text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]"
          >
            Actors
          </p>
          <ul class="space-y-0.5">
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/actors"}
              icon="ri-user-line"
            >
              People
            </.sidebar_item>
            <.sidebar_item
              current_path={@current_path}
              navigate={~p"/#{@account}/service_accounts"}
              icon="ri-robot-3-line"
            >
              Service Accounts
            </.sidebar_item>
          </ul>
        </div>
      </nav>

      <%!-- Settings --%>
      <div class="border-t border-[var(--border)] py-2 px-2 shrink-0">
        <% settings_active? = String.contains?(@current_path, "/settings") %>
        <.link
          navigate={~p"/#{@account}/settings/account"}
          data-sidebar-nav-item
          class={[
            "flex items-center gap-2.5 px-2 py-1.5 rounded text-sm transition-colors",
            settings_active? && "bg-[var(--brand-muted)] text-[var(--brand)] font-medium",
            not settings_active? &&
              "text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)]"
          ]}
        >
          <.icon name="ri-settings-3-line" class="w-4 h-4 shrink-0" />
          <span
            data-sidebar-label
            class="whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
          >
            Settings
          </span>
        </.link>
      </div>

      <%!-- Footer: collapse toggle --%>
      <div class="border-t border-[var(--border)] p-2 space-y-0.5 shrink-0">
        <button
          id="sidebar-toggle"
          phx-hook="SidebarCollapse"
          data-sidebar-nav-item
          type="button"
          class="flex items-center gap-2 w-full px-2 py-1.5 rounded text-sm text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          title="Toggle sidebar"
        >
          <.icon
            name="ri-arrow-left-s-fill"
            data-sidebar-chevron
            class="w-4 h-4 shrink-0 transition-transform duration-200"
          />
          <span
            data-sidebar-label
            class="text-sm whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
          >
            Collapse
          </span>
        </button>
      </div>
    </aside>
    """
  end

  @doc """
  Renders a sidebar navigation item.
  """
  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true
  attr :current_path, :string, required: true

  def sidebar_item(assigns) do
    active? = sidebar_item_active?(assigns.current_path, assigns.navigate)
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <li>
      <.link
        navigate={@navigate}
        data-sidebar-nav-item
        class={[
          "flex items-center gap-2.5 px-2 py-1.5 rounded text-sm transition-colors",
          @active? && "bg-[var(--brand-muted)] text-[var(--brand)] font-medium",
          not @active? &&
            "text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)]"
        ]}
      >
        <.icon name={@icon} class="w-4 h-4 shrink-0" />
        <span
          data-sidebar-label
          class="whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
        >
          {render_slot(@inner_block)}
        </span>
      </.link>
    </li>
    """
  end

  @doc """
  Renders the settings page header (account info) and tab strip.
  Used at the top of each settings sub-page in place of breadcrumbs.
  """
  attr :account, :any, required: true
  attr :current_path, :string, required: true

  def settings_nav(assigns) do
    ~H"""
    <div class="flex flex-col bg-[var(--surface)]">
      <%!-- Page header --%>
      <div class="relative overflow-hidden px-6 pt-6 pb-5 border-b border-[var(--border)]">
        <div class="absolute inset-x-0 top-0 h-[2px] bg-[var(--brand)] opacity-50"></div>
        <div class="flex items-center gap-5">
          <.icon name="ri-settings-3-line" class="shrink-0 w-16 h-16 text-[var(--brand)]" />
          <div class="flex-1 min-w-0">
            <h1 class="text-base font-semibold text-[var(--text-primary)]">{@account.name}</h1>
            <p class="mt-0.5 text-sm text-[var(--text-secondary)]">{@account.legal_name}</p>
            <div class="flex items-start gap-6 md:gap-12 mt-4">
              <div class="flex flex-col gap-0.5">
                <span class="text-[10px] text-[var(--text-tertiary)] uppercase tracking-widest font-semibold">
                  Slug
                </span>
                <span class="font-mono text-xs text-[var(--text-primary)]">{@account.slug}</span>
              </div>
              <div class="hidden md:flex flex-col gap-0.5">
                <span class="text-[10px] text-[var(--text-tertiary)] uppercase tracking-widest font-semibold">
                  Key
                </span>
                <span class="font-mono text-xs text-[var(--text-primary)]">{@account.key}</span>
              </div>
              <div class="hidden md:flex flex-col gap-0.5">
                <span class="text-[10px] text-[var(--text-tertiary)] uppercase tracking-widest font-semibold">
                  ID
                </span>
                <span class="font-mono text-xs text-[var(--text-primary)]">{@account.id}</span>
              </div>
              <div class="flex flex-col gap-0.5">
                <span class="text-[10px] text-[var(--text-tertiary)] uppercase tracking-widest font-semibold">
                  Member Since
                </span>
                <span class="text-xs text-[var(--text-primary)]">
                  {format_member_since(@account.inserted_at)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
      <%!-- Tab strip --%>
      <div class="flex overflow-x-auto overflow-y-hidden border-b border-[var(--border)] px-6 shrink-0 bg-[var(--surface)]">
        <.settings_tab
          current_path={@current_path}
          navigate={~p"/#{@account}/settings/account"}
          tab_path="settings/account"
          icon="ri-building-fill"
        >
          Account
        </.settings_tab>
        <.settings_tab
          current_path={@current_path}
          navigate={~p"/#{@account}/settings/notifications"}
          tab_path="settings/notifications"
          icon="ri-notification-fill"
        >
          Notifications
        </.settings_tab>
        <.settings_tab
          current_path={@current_path}
          navigate={~p"/#{@account}/settings/authentication"}
          tab_path="settings/authentication"
          icon="ri-key-fill"
        >
          Authentication
        </.settings_tab>
        <.settings_tab
          current_path={@current_path}
          navigate={~p"/#{@account}/settings/directory_sync"}
          tab_path="settings/directory_sync"
          icon="ri-loop-left-fill"
        >
          Directory Sync
        </.settings_tab>
        <.settings_tab
          current_path={@current_path}
          navigate={~p"/#{@account}/settings/dns"}
          tab_path="settings/dns"
          icon="ri-global-fill"
        >
          DNS
        </.settings_tab>
        <.settings_tab
          current_path={@current_path}
          navigate={~p"/#{@account}/settings/api_clients"}
          tab_path="settings/api_clients"
          icon="ri-code-s-slash-fill"
        >
          REST API
        </.settings_tab>
      </div>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :current_path, :string, required: true
  attr :tab_path, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp settings_tab(assigns) do
    active? = settings_tab_active?(assigns.current_path, assigns.tab_path)
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2 px-5 py-3 text-sm font-medium border-b-2 -mb-px whitespace-nowrap transition-colors",
        @active? && "border-[var(--brand)] text-[var(--brand)]",
        not @active? &&
          "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
      ]}
    >
      <.icon name={@icon} class="w-4 h-4 shrink-0" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp settings_tab_active?(current_path, tab_path) do
    [_, _slug_or_id, current_subpath] = String.split(current_path, "/", parts: 3)
    String.starts_with?(current_subpath, tab_path)
  end

  defp format_member_since(nil), do: "—"

  defp format_member_since(dt) do
    date = DateTime.to_date(dt)
    month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), date.month - 1)
    "#{month} #{date.day}, #{date.year}"
  end

  defp sidebar_item_active?(current_path, destination_path) do
    [_, _slug_or_id, current_subpath] = String.split(current_path, "/", parts: 3)
    [_, _slug_or_id, destination_subpath] = String.split(destination_path, "/", parts: 3)
    String.starts_with?(current_subpath, destination_subpath)
  end

  attr :id, :string, required: true, doc: "ID of the nav group container"
  slot :button, required: true
  slot :dropdown, required: true

  def dropdown(assigns) do
    ~H"""
    <button
      type="button"
      class="flex mx-3 text-sm bg-neutral-800 rounded-full md:mr-0"
      id={"#{@id}-button"}
      aria-expanded="false"
      data-dropdown-toggle={"#{@id}-dropdown"}
    >
      {render_slot(@button)}
    </button>
    <div
      class="hidden z-50 my-4 w-56 text-base list-none bg-[var(--surface-overlay)] rounded-sm divide-y divide-[var(--border)] shadow-sm"
      id={"#{@id}-dropdown"}
    >
      {render_slot(@dropdown)}
    </div>
    """
  end

  @doc """
  Renders breadcrumbs section. For entries `<.breadcrumb />` component should be used.
  """
  attr :account, :any,
    required: false,
    default: nil,
    doc: "Account assign which will be used to fetch the home path."

  slot :inner_block, required: true, doc: "Breadcrumb entries"

  def breadcrumbs(assigns) do
    ~H"""
    <nav class="py-3 px-4" aria-label="Breadcrumb">
      <ol class="inline-flex items-center space-x-1 md:space-x-2">
        <li class="inline-flex items-center">
          <.link
            navigate={if @account, do: ~p"/#{@account}/sites", else: @home_path}
            class="inline-flex items-center text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
          >
            <.icon name="ri-home-2-fill" class="w-3.5 h-3.5 mr-2" /> Home
          </.link>

          {render_slot(@inner_block)}
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  Renders a single breadcrumb entry. Should be wrapped in <.breadcrumbs> component.
  """
  slot :inner_block, required: true, doc: "The label for the breadcrumb entry."
  attr :path, :string, default: nil, doc: "The path for the breadcrumb entry."

  def breadcrumb(assigns) do
    ~H"""
    <li class="inline-flex items-center">
      <div class="flex items-center text-[var(--text-tertiary)]">
        <.icon name="ri-arrow-right-s-fill" class="w-3.5 h-3.5" />
        <.link
          :if={not is_nil(@path)}
          navigate={@path}
          class="ml-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)] md:ml-2"
        >
          {render_slot(@inner_block)}
        </.link>

        <span :if={is_nil(@path)} class="ml-1 text-sm text-[var(--text-primary)] md:ml-2">
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
        class="text-sm font-semibold leading-6 text-[var(--text-primary)] hover:text-[var(--text-secondary)]"
      >
        <.icon name="ri-arrow-left-fill" class="h-3 w-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders links based off our website path.

  ## Examples

    <.website_link path="/pricing">Pricing</.website_link>
    <.website_link path="/kb/deploy/gateways">Deploy Gateway(s)</.website_link>
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

    <.docs_action path="/kb/deploy/gateways">Deploy Gateway(s)</.docs_action>
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
      <.icon name="ri-question-line" class="mr-2 w-5 h-5" />
    </.link>
    """
  end
end
