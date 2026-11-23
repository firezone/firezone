defmodule PortalWeb.Components.Navigation do
  use Phoenix.Component
  import Phoenix.Component, except: [link: 1]
  use PortalWeb, :verified_routes
  alias Phoenix.LiveView.JS
  alias PortalWeb.Components.Core

  @doc """
  Renders a Phoenix link with the default text-link styling.

  Supply `class` to replace the default styling for buttons, navigation items,
  or other custom links. All navigation, method, and CSRF behavior is delegated
  to `Phoenix.Component.link/1`.
  """
  attr :href, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :replace, :boolean, default: false
  attr :method, :string, default: "get"
  attr :csrf_token, :any, default: true
  attr :class, :any, default: ["text-link", "hover:underline"]
  attr :rest, :global, include: ~w(download hreflang referrerpolicy rel target type)

  slot :inner_block, required: true

  def link(assigns) do
    ~H"""
    <Phoenix.Component.link
      href={@href}
      navigate={@navigate}
      patch={@patch}
      replace={@replace}
      method={@method}
      csrf_token={@csrf_token}
      class={@class}
      {@rest}
    >{render_slot(@inner_block)}</Phoenix.Component.link>
    """
  end
  @doc """
  Renders the account menu: who is signed in, their settings, the theme, and sign out.
  """
  attr :subject, :any, required: true

  def subject_dropdown(assigns) do
    ~H"""
    <div class="px-4 py-3">
      <span class="block text-sm font-medium text-fg truncate">{@subject.actor.name}</span>
      <span class="block text-xs text-muted truncate">{@subject.actor.email}</span>
    </div>
    <ul class="py-1" aria-labelledby="user-menu-button">
      <li>
        <.link
          navigate={~p"/#{@subject.account}/settings/profile"}
          class="flex items-center gap-2.5 py-2 px-4 text-fg hover:bg-hover"
        >
          <Core.icon name="ri-user-settings-line" class="w-4 h-4 shrink-0 text-muted" />
          Your settings
        </.link>
      </li>
      <li :if={PortalWeb.GettingStarted.offered?(@subject.actor)}>
        <button
          id="open-getting-started"
          type="button"
          phx-click={
            JS.dispatch("popover:hide", to: "#user-menu-button")
            |> JS.push("open", target: "#getting-started")
          }
          class="flex items-center gap-2.5 w-full text-left py-2 px-4 text-fg hover:bg-hover"
        >
          <Core.icon name="ri-rocket-2-line" class="w-4 h-4 shrink-0 text-muted" /> Getting started
        </button>
      </li>
      <li>
        <a
          target="_blank"
          href="https://www.firezone.dev/kb?utm_source=product"
          rel="noopener noreferrer"
          class="flex items-center gap-2.5 py-2 px-4 text-fg hover:bg-hover"
        >
          <Core.icon name="ri-book-open-line" class="w-4 h-4 shrink-0 text-muted" /> Docs
          <Core.icon name="ri-arrow-right-up-line" class="w-3 h-3 ml-auto text-faint" />
        </a>
      </li>
      <li>
        <a
          target="_blank"
          href="https://firezone.statuspage.io"
          rel="noopener noreferrer"
          class="flex items-center gap-2.5 py-2 px-4 text-fg hover:bg-hover"
        >
          <Core.icon name="ri-pulse-line" class="w-4 h-4 shrink-0 text-muted" /> Status
          <Core.icon name="ri-arrow-right-up-line" class="w-3 h-3 ml-auto text-faint" />
        </a>
      </li>
    </ul>
    <div id="theme-toggle" phx-hook="ThemeToggle" class="px-4 py-3">
      <p class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted mb-2">Theme</p>
      <div class="grid grid-cols-3 border border-hair" role="listbox" aria-label="Theme">
        <button
          :for={
            {theme, icon, label} <- [
              {"system", "ri-computer-line", "System"},
              {"light", "ri-sun-line", "Light"},
              {"dark", "ri-moon-line", "Dark"}
            ]
          }
          type="button"
          role="option"
          data-theme-option={theme}
          class="flex flex-col items-center gap-1 py-2 text-xs text-muted hover:text-fg hover:bg-hover"
        >
          <Core.icon name={icon} class="w-4 h-4" />
          {label}
        </button>
      </div>
    </div>
    <ul class="py-1">
      <li>
        <form id="sign-out-form" action={~p"/#{@subject.account}/sign_out"} method="post">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button
            type="submit"
            class="flex items-center gap-2.5 w-full text-left py-2 px-4 text-fg hover:bg-hover"
          >
            <Core.icon name="ri-logout-box-r-line" class="w-4 h-4 shrink-0 text-muted" /> Sign out
          </button>
        </form>
      </li>
    </ul>
    """
  end

  @doc """
  The portal's four places, in sidebar order, plus Settings.

  Each section owns the tabs drawn across the top of its pages. A tab is active
  when the current path starts with its path; the longest match wins, so
  `activity/map` beats `activity`.
  """
  @spec sections(Portal.Account.t()) :: [map()]
  def sections(account) do
    [
      %{
        key: :activity,
        label: "Activity",
        icon: "ri-pulse-line",
        match: ~w[activity logs],
        tabs: [
          {"All", "ri-stack-line", ~p"/#{account}/activity"},
          {"Map", "ri-earth-line", ~p"/#{account}/activity/map"},
          {"Changes", "ri-history-line", ~p"/#{account}/logs/change_logs"},
          {"Sessions", "ri-login-circle-line", ~p"/#{account}/logs/session_logs"},
          {"Flows", "ri-arrow-left-right-line", ~p"/#{account}/logs/flow_logs"},
          {"API requests", "ri-terminal-box-line", ~p"/#{account}/logs/api_request_logs"}
        ]
      },
      %{
        key: :team,
        label: "Team",
        icon: "ri-team-line",
        match: ~w[actors service_accounts groups],
        tabs: [
          {"People", "ri-user-line", ~p"/#{account}/actors"},
          {"Service accounts", "ri-robot-2-line", ~p"/#{account}/service_accounts"},
          {"Groups", "ri-group-line", ~p"/#{account}/groups"}
        ]
      },
      %{
        key: :access,
        label: "Access",
        icon: "ri-shield-keyhole-line",
        match: ~w[access policies],
        tabs: [
          {"Graph", "ri-git-merge-line", ~p"/#{account}/access"},
          {"Policies", "ri-shield-check-line", ~p"/#{account}/policies"},
          {"By group", "ri-group-line", ~p"/#{account}/access/by_group"},
          {"By resource", "ri-server-line", ~p"/#{account}/access/by_resource"}
        ]
      },
      %{
        key: :routing,
        label: "Routing",
        icon: "ri-route-line",
        match: ~w[resources sites devices],
        tabs: [
          {"Resources", "ri-server-line", ~p"/#{account}/resources"},
          {"Sites", "ri-map-pin-line", ~p"/#{account}/sites"},
          {"Devices", "ri-computer-line", ~p"/#{account}/devices"}
        ]
      }
    ]
  end

  @doc "The Settings section. Its tabs sit across the top of every settings page."
  @spec settings_section(Portal.Account.t()) :: map()
  def settings_section(account) do
    %{
      key: :settings,
      label: "Settings",
      icon: "ri-settings-3-line",
      match: ~w[settings],
      tabs: [
        {"Account", "ri-building-line", ~p"/#{account}/settings/account"},
        {"Authentication", "ri-key-2-line", ~p"/#{account}/settings/authentication"},
        {"Directory sync", "ri-loop-left-line", ~p"/#{account}/settings/directory_sync"},
        {"Device posture", "ri-shield-star-line", ~p"/#{account}/settings/device_posture"},
        {"Log sinks", "ri-upload-cloud-2-line", ~p"/#{account}/settings/log_sinks"},
        {"DNS", "ri-global-line", ~p"/#{account}/settings/dns"},
        {"REST API", "ri-code-s-slash-line", ~p"/#{account}/settings/api_clients"},
        {"Trust anchors", "ri-shield-check-line", ~p"/#{account}/settings/trust_anchors"}
      ]
    }
  end

  @doc "The section that owns `current_path`, or nil (for example on the profile page)."
  @spec current_section(Portal.Account.t(), String.t()) :: map() | nil
  def current_section(account, current_path) do
    subpath = subpath(current_path)

    cond do
      String.starts_with?(subpath, "settings/profile") ->
        nil

      String.starts_with?(subpath, "settings") ->
        settings_section(account)

      true ->
        Enum.find(sections(account), fn section ->
          Enum.any?(section.match, &path_prefix?(subpath, &1))
        end)
    end
  end

  @doc """
  Renders the sidebar: the brand, the four sections, Settings, and the account menu.
  """
  attr :account, :any, required: true
  attr :current_path, :string, required: true
  attr :subject, :any, required: true

  def sidebar(assigns) do
    section = current_section(assigns.account, assigns.current_path)

    assigns =
      assign(assigns,
        sections: sections(assigns.account),
        active_key: section && section.key
      )

    ~H"""
    <aside
      id="sidebar"
      class="flex flex-col shrink-0 border-r border-rule bg-bg overflow-hidden transition-[width] duration-200 ease-in-out w-56 z-20"
    >
      <div data-sidebar-wordmark class="flex items-center h-14 px-5 shrink-0">
        <a
          href={PortalWeb.Session.Redirector.default_portal_path(@account, @subject.actor)}
          class="flex items-center gap-2.5 min-w-0"
        >
          <img src={~p"/images/logo.svg"} class="h-5 w-auto shrink-0" alt="Firezone Logo" />
          <span
            data-sidebar-label
            class="font-semibold text-[15px] text-fg whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
          >
            Firezone
          </span>
          <span
            data-sidebar-label
            class="text-[15px] text-muted truncate transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
          >
            {@account.name}
          </span>
        </a>
      </div>

      <nav class="flex-1 overflow-y-auto py-3" aria-label="Main">
        <ul>
          <.sidebar_item
            :for={section <- @sections}
            navigate={section_landing(section)}
            icon={section.icon}
            active?={section.key == @active_key}
            id={"nav-#{section.key}"}
          >
            {section.label}
          </.sidebar_item>
        </ul>
      </nav>

      <.live_component module={PortalWeb.GettingStarted} id="getting-started" subject={@subject} />

      <div class="border-t border-hair py-2 shrink-0">
        <ul>
          <.sidebar_item
            navigate={~p"/#{@account}/settings/account"}
            icon="ri-settings-3-line"
            active?={@active_key == :settings}
            id="nav-settings"
          >
            Settings
          </.sidebar_item>
        </ul>
      </div>

      <div
        data-sidebar-label
        class="flex items-center gap-3 px-5 pb-2 text-xs text-muted transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
      >
        <.live_component module={PortalWeb.SupportForm} id="support" subject={@subject} />
      </div>

      <div class="border-t border-hair px-3 py-2 shrink-0 flex items-center gap-1">
        <.dropdown id="user-menu" placement="top-start">
          <:button>
            <span class="sr-only">Open user menu</span>
            <Core.avatar account={@subject.account} actor={@subject.actor} class="w-6 h-6" />
            <span
              data-sidebar-label
              class="min-w-0 flex-1 text-left truncate text-sm text-fg transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
            >
              {@subject.actor.name}
            </span>
          </:button>
          <:dropdown>
            <.subject_dropdown subject={@subject} />
          </:dropdown>
        </.dropdown>
        <button
          id="sidebar-toggle"
          phx-hook="SidebarCollapse"
          data-sidebar-label
          type="button"
          class="ml-auto shrink-0 flex items-center justify-center w-7 h-7 text-muted hover:text-fg hover:bg-hover transition-[max-width,opacity] duration-200 max-w-xs opacity-100"
          title="Collapse sidebar"
          aria-label="Collapse sidebar"
        >
          <Core.icon
            name="ri-side-bar-line"
            data-sidebar-chevron
            class="w-4 h-4 shrink-0 transition-transform duration-200"
          />
        </button>
      </div>
    </aside>
    """
  end

  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  attr :active?, :boolean, required: true
  attr :id, :string, default: nil
  attr :badge, :string, default: nil
  slot :inner_block, required: true

  defp sidebar_item(assigns) do
    ~H"""
    <li>
      <.link
        id={@id}
        navigate={@navigate}
        data-sidebar-nav-item
        aria-current={@active? && "page"}
        class={[
          "relative flex items-center gap-3 pl-[18px] pr-5 py-2 text-sm border-l-2 overflow-hidden transition-colors",
          @active? && "border-fg text-fg font-medium bg-hover",
          not @active? && "border-transparent text-muted hover:text-fg"
        ]}
      >
        <Core.icon name={@icon} class="w-4 h-4 shrink-0" />
        <span
          data-sidebar-label
          class="whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100 flex-1"
        >
          {render_slot(@inner_block)}
        </span>
        <Core.new_badge :if={@badge} label={@badge} class="ml-auto" data-sidebar-badge />
      </.link>
    </li>
    """
  end

  @doc """
  Renders the tab strip for the section that owns `current_path`.

  The app layout draws this above every page, so pages never draw their own
  section navigation.
  """
  attr :account, :any, required: true
  attr :current_path, :string, required: true

  def section_tabs(assigns) do
    section = current_section(assigns.account, assigns.current_path)
    active = section && active_tab(section, assigns.current_path)
    assigns = assign(assigns, section: section, active: active)

    ~H"""
    <nav
      :if={@section}
      id="section-tabs"
      aria-label={@section.label}
      class="flex items-center gap-6 h-[42px] px-6 border-b border-hair shrink-0 overflow-x-auto no-scrollbar bg-bg"
    >
      <.link
        :for={{label, icon, path} <- @section.tabs}
        navigate={path}
        data-section-tab
        aria-current={path == @active && "page"}
        class={[
          "flex items-center gap-1.5 h-full text-sm whitespace-nowrap border-b-2 -mb-px transition-colors",
          path == @active && "border-fg text-fg",
          path != @active && "border-transparent text-muted hover:text-fg"
        ]}
      >
        <Core.icon name={icon} class="w-3.5 h-3.5 shrink-0" />
        {label}
      </.link>
    </nav>
    """
  end

  @doc """
  Renders the account header shown at the top of the account settings page.
  """
  attr :account, :any, required: true
  attr :current_path, :string, required: true
  slot :actions

  def settings_nav(assigns) do
    ~H"""
    <div class="px-6 pt-7 pb-5 shrink-0">
      <div class="flex items-end gap-4">
        <div class="min-w-0">
          <h1 class="text-[26px] leading-tight font-bold tracking-tight text-fg">{@account.name}</h1>
          <p class="mt-1 text-sm text-muted">{@account.legal_name}</p>
        </div>
        <div :if={@actions != []} class="ml-auto shrink-0">
          {render_slot(@actions)}
        </div>
      </div>
      <dl class="flex flex-wrap items-start gap-x-10 gap-y-3 mt-5">
        <div>
          <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Slug</dt>
          <dd class="mt-1 font-mono text-xs text-fg">{@account.slug}</dd>
        </div>
        <div class="hidden md:block">
          <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Key</dt>
          <dd class="mt-1 font-mono text-xs text-fg">{@account.key}</dd>
        </div>
        <div class="hidden md:block">
          <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">ID</dt>
          <dd class="mt-1 font-mono text-xs text-fg">{@account.id}</dd>
        </div>
        <div>
          <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            Member since
          </dt>
          <dd class="mt-1 text-xs text-fg">{format_member_since(@account.inserted_at)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp section_landing(%{tabs: [{_label, _icon, path} | _]}), do: path

  defp active_tab(section, current_path) do
    current = subpath(current_path)

    section.tabs
    |> Enum.map(fn {_label, _icon, path} -> path end)
    |> Enum.filter(&path_prefix?(current, subpath(&1)))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp path_prefix?(subpath, prefix) do
    subpath == prefix or String.starts_with?(subpath, prefix <> "/") or
      String.starts_with?(subpath, prefix <> "?")
  end

  defp subpath(path) do
    case String.split(path, "/", parts: 3) do
      [_, _slug_or_id, subpath] -> subpath |> String.split("?", parts: 2) |> hd()
      _ -> ""
    end
  end

  defp format_member_since(nil), do: "—"

  defp format_member_since(dt) do
    date = DateTime.to_date(dt)
    month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), date.month - 1)
    "#{month} #{date.day}, #{date.year}"
  end

  attr :id, :string, required: true, doc: "ID of the menu"
  attr :placement, :string, default: "bottom"
  slot :button, required: true
  slot :dropdown, required: true

  def dropdown(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "group flex items-center gap-2 min-w-0 flex-1 px-1.5 py-1 text-sm",
        "text-fg hover:bg-hover transition-colors aria-expanded:bg-hover"
      ]}
      id={"#{@id}-button"}
      data-sidebar-nav-item
      phx-hook="Popover"
      data-popover-target-id={"#{@id}-dropdown"}
      data-popover-trigger="click"
      data-popover-placement={@placement}
    >
      {render_slot(@button)}
      <Core.icon
        name="ri-arrow-down-s-line"
        data-sidebar-label
        class="w-4 h-4 shrink-0 text-muted transition-transform group-aria-expanded:rotate-180"
      />
    </button>
    <div
      class="invisible opacity-0 fixed z-50 w-64 text-sm bg-bg border border-rule shadow-md divide-y divide-hair"
      id={"#{@id}-dropdown"}
    >
      {render_slot(@dropdown)}
    </div>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <Navigation.back navigate={~p"/posts"}>Back to posts</Navigation.back>
  """
  attr :navigate, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link
        navigate={@navigate}
        class="text-sm font-semibold leading-6 text-heading hover:text-body"
      >
        <Core.icon name="ri-arrow-left-fill" class="h-3 w-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders links based off our website path.

  ## Examples

    <Navigation.website_link path="/pricing">Pricing</Navigation.website_link>
    <Navigation.website_link path="/kb/deploy/gateways">Deploy Gateway(s)</Navigation.website_link>
    <Navigation.website_link path="/contact/sales">Contact Sales</Navigation.website_link>
  """
  attr :path, :string, required: true
  attr :fragment, :string, required: false, default: ""
  attr :class, :string, default: nil
  slot :inner_block, required: true
  attr :rest, :global

  def website_link(assigns) do
    ~H"""
    <.link
      href={"https://www.firezone.dev#{@path}?utm_source=product##{@fragment}"}
      class={@class || Core.link_style()}
      target="_blank"
      rel="noopener noreferrer"
      {@rest}
    >{render_slot(@inner_block)}</.link>
    """
  end

  @doc """
  Renders links to the docs based off documentation portal path.

  ## Examples

    <Navigation.docs_action path="/deploy/gateways" show_label />
  """
  attr :path, :string, required: true
  attr :fragment, :string, required: false, default: ""
  attr :show_label, :boolean, default: false
  attr :size, :string, default: "sm", values: ~w[sm md]
  attr :rest, :global

  def docs_action(assigns) do
    ~H"""
    <.link
      title="View documentation for this page"
      aria-label="View documentation for this page"
      class={[
        "inline-flex items-center mr-2 text-body hover:text-heading",
        @size == "sm" && "gap-1 text-xs",
        @size == "md" && "gap-1.5 text-sm"
      ]}
      href={"https://www.firezone.dev/kb#{@path}?utm_source=product##{@fragment}"}
      target="_blank"
      rel="noopener noreferrer"
      {@rest}
    >
      <Core.icon
        name="ri-book-open-line"
        class={["shrink-0", @size == "sm" && "w-3 h-3", @size == "md" && "w-4 h-4"]}
        aria-hidden="true"
      />
      <span :if={@show_label}>Docs</span>
    </.link>
    """
  end
end
