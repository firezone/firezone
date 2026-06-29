defmodule PortalWeb.Sites.Components do
  use PortalWeb, :component_library

  attr :state, :map, required: true

  def new_site_panel(assigns) do
    assigns = assign(assigns, assigns.state)

    ~H"""
    <div
      id="new-site-panel"
      class={[
        "absolute inset-y-0 right-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-96",
        "bg-elevated border-l border-border-strong",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@open, do: "translate-x-0", else: "translate-x-full")
      ]}
    >
      <div :if={@open} class="flex flex-col h-full overflow-hidden">
        <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-border">
          <h2 class="text-sm font-semibold text-heading">New Site</h2>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_new_site_panel" />
        </div>
        <div class="flex-1 overflow-y-auto px-5 py-4">
          <.form for={@form} phx-change="new_site_change" phx-submit="new_site_submit">
            <div class="space-y-4">
              <.input
                label="Name"
                field={@form[:name]}
                placeholder="Enter a name for this site"
                phx-debounce="300"
                required
              />
              <div>
                <.input
                  field={@form[:health_threshold]}
                  type="number"
                  label="Health threshold"
                  min="1"
                />
                <p class="mt-1.5 text-xs text-subtle">
                  Minimum number of gateways that must be online for this site to be considered healthy.
                </p>
              </div>
            </div>
            <div class="flex items-center justify-end gap-2 mt-6">
              <.button type="button" phx-click="close_new_site_panel">
                Cancel
              </.button>
              <.button type="submit" style="primary" disabled={not @form.source.valid?}>
                Create Site
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :account, :any, required: true
  attr :resources_counts, :map, required: true
  attr :policies_counts, :map, required: true
  attr :gateway_counts, :map, required: true
  attr :panel, :map, required: true
  attr :deploy_state, :map, required: true
  attr :resource_form_state, :map, required: true
  attr :edit_state, :map, required: true

  def site_panel(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(
        deploy_env: assigns.deploy_state.env,
        deploy_tab: assigns.deploy_state.tab,
        deploy_connected?: assigns.deploy_state.connected?,
        deploy_token: assigns.deploy_state.token,
        resource_form: assigns.resource_form_state.form,
        filters_dropdown_open: assigns.resource_form_state.filters_dropdown_open,
        active_protocols: assigns.resource_form_state.active_protocols,
        form: assigns.edit_state.form
      )

    filter_ports =
      if assigns.resource_form do
        assigns.resource_form.source
        |> Ecto.Changeset.get_field(:filters, [])
        |> Map.new(fn f -> {f.protocol, Enum.join(f.ports, ", ")} end)
      else
        %{}
      end

    assigns = assign(assigns, :filter_ports, filter_ports)

    assigns =
      if assigns.site do
        assigns
        |> assign(:total_count, Map.get(assigns.gateway_counts, assigns.site.id, 0))
        |> assign(:status, site_status(assigns.gateways, assigns.site.health_threshold))
      else
        assigns
        |> assign(:total_count, 0)
        |> assign(:status, :offline)
      end

    ~H"""
    <div
      id="site-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-elevated border-l border-border-strong",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@site, do: "translate-x-0", else: "translate-x-full")
      ]}
    >
      <div :if={@site} class="flex flex-col h-full overflow-hidden">
        <.site_panel_header
          :if={@view != :edit_site}
          site={@site}
          view={@view}
          status={@status}
        />

        <.site_overview_view
          :if={@view == :gateways}
          site={@site}
          account={@account}
          panel={@panel}
          gateways={@gateways}
          resources={@resources}
          gateway_counts={@gateway_counts}
          resources_counts={@resources_counts}
        />

        <.site_deploy_view
          :if={@view == :deploy}
          account={@account}
          site={@site}
          deploy_env={@deploy_env}
          deploy_tab={@deploy_tab}
          deploy_connected?={@deploy_connected?}
        />

        <.site_add_resource_view
          :if={@view == :add_resource}
          resource_form={@resource_form}
          filters_dropdown_open={@filters_dropdown_open}
          active_protocols={@active_protocols}
          filter_ports={@filter_ports}
        />

        <.site_edit_view :if={@view == :edit_site} site={@site} form={@form} />
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :view, :atom, required: true
  attr :status, :atom, required: true

  def site_panel_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 py-4 border-b border-border bg-elevated">
      <div class="flex items-center gap-4">
        <%!-- Left: name + status + ID --%>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold text-heading truncate">{@site.name}</h2>
            <.badge :if={@site.managed_by == :system} type="accent" size="xs">system</.badge>
            <.site_status_badge status={@status} />
          </div>
          <p class="font-mono text-xs text-subtle mt-0.5 truncate">{@site.id}</p>
        </div>
        <%!-- Right: actions --%>
        <div class="flex items-center gap-1.5 shrink-0">
          <.button :if={@view == :gateways} phx-click="open_site_edit_form" size="sm">
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </.button>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
        </div>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :account, :any, required: true
  attr :panel, :map, required: true
  attr :gateways, :list, required: true
  attr :resources, :list, required: true
  attr :gateway_counts, :map, required: true
  attr :resources_counts, :map, required: true

  def site_overview_view(assigns) do
    assigns = assign(assigns, assigns.panel)

    ~H"""
    <div class="flex flex-1 min-h-0 divide-x divide-border overflow-hidden">
      <div class="flex-1 flex flex-col overflow-hidden">
        <.site_panel_tabs
          site={@site}
          tab={@tab}
          show_all_gateways={@show_all_gateways}
          total_count={Map.get(@gateway_counts, @site.id, 0)}
          resource_count={length(@resources)}
        />

        <.site_gateways_tab
          :if={@tab == :gateways}
          site={@site}
          gateways={@gateways}
          gateway_counts={@gateway_counts}
          expanded_gateway_id={@expanded_gateway_id}
        />

        <.site_resources_tab
          :if={@tab == :resources}
          site={@site}
          account={@account}
          resources={@resources}
        />
      </div>

      <.site_sidebar site={@site} confirm_delete_site={@confirm_delete_site} />
    </div>
    """
  end

  attr :site, :any, required: true
  attr :tab, :atom, required: true
  attr :show_all_gateways, :boolean, required: true
  attr :total_count, :integer, required: true
  attr :resource_count, :integer, required: true

  def site_panel_tabs(assigns) do
    ~H"""
    <div class="flex items-end gap-0 px-5 border-b border-border bg-raised shrink-0">
      <button
        phx-click="switch_panel_tab"
        phx-value-tab="gateways"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :gateways,
            do: "border-brand text-brand",
            else:
              "border-transparent text-body hover:text-heading hover:border-border-strong"
          )
        ]}
      >
        Gateways
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :gateways,
            do: "bg-brand-muted text-brand",
            else: "bg-raised text-subtle"
          )
        ]}>
          {@total_count}
        </span>
      </button>
      <button
        phx-click="switch_panel_tab"
        phx-value-tab="resources"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :resources,
            do: "border-brand text-brand",
            else:
              "border-transparent text-body hover:text-heading hover:border-border-strong"
          )
        ]}
      >
        Resources
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :resources,
            do: "bg-brand-muted text-brand",
            else: "bg-raised text-subtle"
          )
        ]}>
          {@resource_count}
        </span>
      </button>
      <div class="ml-auto pb-2 flex items-center gap-2">
        <.button :if={@tab == :gateways} phx-click="deploy_gateway" size="xs">
          <.icon name="ri-add-line" class="w-3 h-3" /> Deploy gateway
        </.button>
        <.button
          :if={@tab == :resources and @site.managed_by == :account}
          phx-click="add_resource"
          size="xs"
        >
          <.icon name="ri-add-line" class="w-3 h-3" /> Add resource
        </.button>
        <.button
          :if={@tab == :gateways and not @show_all_gateways}
          phx-click="show_all_gateways"
          size="xs"
        >
          View all <.icon name="ri-arrow-right-line" class="w-3 h-3" />
        </.button>
        <.button
          :if={@tab == :gateways and @show_all_gateways}
          phx-click="show_online_gateways"
          size="xs"
        >
          Online only
        </.button>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :gateways, :list, required: true
  attr :gateway_counts, :map, required: true
  attr :expanded_gateway_id, :string, default: nil

  def site_gateways_tab(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li
          :for={gateway <- @gateways}
          phx-click="toggle_gateway_expand"
          phx-value-id={gateway.id}
          class="border-b border-border hover:bg-raised cursor-pointer transition-colors group"
        >
          <div class="flex items-center gap-3 px-5 py-3">
            <div class="flex items-center justify-center w-7 h-7 rounded border border-border-strong bg-raised shrink-0">
              <svg
                class="w-3.5 h-3.5 text-subtle"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <rect x="1.5" y="4" width="13" height="8" rx="1" />
                <circle cx="4" cy="8" r="0.75" fill="currentColor" stroke="none" />
                <circle cx="6.5" cy="8" r="0.75" fill="currentColor" stroke="none" />
                <path d="M10 8h3.5" />
              </svg>
            </div>
            <div class="flex-1 min-w-0">
              <p class="font-mono text-sm font-medium text-heading truncate group-hover:text-brand transition-colors">
                {gateway.name}
              </p>
              <p
                :if={gateway.latest_session}
                class="font-mono text-xs text-subtle mt-0.5"
              >
                {gateway.latest_session.remote_ip}
              </p>
            </div>
            <span :if={gateway.online?} class="inline-flex items-center gap-1.5 shrink-0">
              <span class="relative flex items-center justify-center w-1.5 h-1.5">
                <span class="absolute inline-flex rounded-full opacity-60 animate-ping w-1.5 h-1.5 bg-success">
                </span>
                <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-success">
                </span>
              </span>
            </span>
            <span :if={not gateway.online?} class="inline-flex items-center gap-1.5 shrink-0">
              <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-neutral-status">
              </span>
            </span>
            <.icon
              name={
                if @expanded_gateway_id == gateway.id,
                  do: "ri-arrow-up-s-line",
                  else: "ri-arrow-down-s-line"
              }
              class="w-4 h-4 text-subtle shrink-0"
            />
          </div>
          <div
            :if={@expanded_gateway_id == gateway.id}
            class="px-5 pb-3 pt-1 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5"
          >
            <span class="text-xs text-subtle">Last started</span>
            <span class="text-xs text-heading">
              <.relative_datetime
                datetime={gateway.latest_session && gateway.latest_session.inserted_at}
                popover={false}
                empty="Unknown"
              />
            </span>
            <span class="text-xs text-subtle">Remote IP</span>
            <span class="text-xs text-heading">
              <.last_seen schema={gateway.latest_session} />
            </span>
            <span class="text-xs text-subtle">Version</span>
            <span class="font-mono text-xs text-heading">
              {gateway.latest_session && gateway.latest_session.version}
            </span>
            <span class="text-xs text-subtle">User agent</span>
            <span class="font-mono text-xs text-heading break-all">
              {gateway.latest_session && gateway.latest_session.user_agent}
            </span>
            <span class="text-xs text-subtle">Tunnel IPv4</span>
            <span class="font-mono text-xs text-heading">
              {gateway.ipv4}
            </span>
            <span class="text-xs text-subtle">Tunnel IPv6</span>
            <span class="font-mono text-xs text-heading">
              {gateway.ipv6}
            </span>
          </div>
        </li>
      </ul>
      <div
        :if={@gateways == [] and Map.get(@gateway_counts, @site.id, 0) == 0}
        class="flex flex-col items-center justify-center gap-3 py-16"
      >
        <p class="text-sm text-subtle">No gateways deployed to this site.</p>
        <button
          phx-click="deploy_gateway"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
        >
          <.icon name="ri-add-line" class="w-3.5 h-3.5" /> Deploy a gateway
        </button>
      </div>
      <div
        :if={@gateways == [] and Map.get(@gateway_counts, @site.id, 0) > 0}
        class="flex items-center justify-center py-16"
      >
        <p class="text-sm text-subtle">
          No gateways are currently online.
        </p>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :account, :any, required: true
  attr :resources, :list, required: true

  def site_resources_tab(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li :for={resource <- @resources} class="border-b border-border">
          <.link
            navigate={~p"/#{@account}/resources/#{resource.id}"}
            class="flex items-center gap-3 px-5 py-3 hover:bg-raised transition-colors group"
          >
            <span class={type_badge_class(resource.type)}>
              {resource.type}
            </span>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-heading truncate group-hover:text-brand transition-colors">
                {resource.name}
              </p>
              <p class="font-mono text-xs text-subtle mt-0.5">
                {resource.address}
              </p>
            </div>
          </.link>
        </li>
      </ul>
      <div :if={@resources == []} class="flex flex-col items-center justify-center gap-3 py-16">
        <p class="text-sm text-subtle">No resources assigned to this site.</p>
        <.button :if={@site.managed_by == :account} phx-click="add_resource" size="xs">
          <.icon name="ri-add-line" class="w-3.5 h-3.5" /> Add a resource
        </.button>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :confirm_delete_site, :boolean, required: true

  def site_sidebar(assigns) do
    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <.site_details_section site={@site} />
      <div :if={@site.managed_by == :account} class="border-t border-border"></div>
      <.site_danger_zone
        :if={@site.managed_by == :account}
        confirm_delete_site={@confirm_delete_site}
      />
    </div>
    """
  end

  attr :site, :any, required: true

  def site_details_section(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
        Details
      </h3>
      <dl class="space-y-2.5">
        <div>
          <dt class="text-[10px] text-subtle mb-0.5">Name</dt>
          <dd class="text-xs text-body truncate" title={@site.name}>
            {@site.name}
          </dd>
        </div>
        <div>
          <dt class="text-[10px] text-subtle mb-0.5">Health threshold</dt>
          <dd class="text-xs text-body">
            {@site.health_threshold}
          </dd>
        </div>
        <div>
          <dt class="text-[10px] text-subtle mb-0.5">ID</dt>
          <dd class="font-mono text-[11px] text-body break-all">
            {@site.id}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :confirm_delete_site, :boolean, required: true

  def site_danger_zone(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error/60 mb-3">
        Danger Zone
      </h3>
      <button
        :if={not @confirm_delete_site}
        type="button"
        phx-click="confirm_delete_site"
        class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
      >
        <.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete site
      </button>
      <div
        :if={@confirm_delete_site}
        class="rounded border border-error/20 bg-error-light p-3 space-y-3"
      >
        <p class="text-xs text-error">
          <span class="font-medium">Delete this Site?</span>
          <br />
          All associated gateways and resources will also be permanently deleted.
        </p>
        <div class="flex items-center gap-2">
          <.button type="button" phx-click="cancel_delete_site" size="xs">
            Cancel
          </.button>
          <.button type="button" phx-click="delete_site" style="danger" size="xs" class="font-medium">
            Delete site
          </.button>
        </div>
      </div>
    </section>
    """
  end

  attr :account, :any, required: true
  attr :site, :any, required: true
  attr :deploy_env, :any, default: nil
  attr :deploy_tab, :string, required: true
  attr :deploy_connected?, :boolean, required: true

  def site_deploy_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <.site_deploy_header />
      <div class="flex-1 overflow-y-auto">
        <.site_deploy_tabs deploy_tab={@deploy_tab} />
        <.site_deploy_instructions deploy_tab={@deploy_tab} deploy_env={@deploy_env} />
      </div>
      <div class="shrink-0 px-5 py-3 border-t border-border bg-raised flex items-center justify-between gap-4">
        <p class="text-xs text-subtle">
          Gateway not connecting? See our
          <.website_link path="/kb/administer/troubleshooting" fragment="gateway-not-connecting">
            troubleshooting guide.
          </.website_link>
        </p>
        <.initial_connection_status
          :if={@deploy_env}
          type="gateway"
          navigate={~p"/#{@account}/sites/#{@site}"}
          connected?={@deploy_connected?}
        />
      </div>
    </div>
    """
  end

  def site_deploy_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-heading">Deploy a Gateway</h2>
        <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_deploy" />
      </div>
    </div>
    """
  end

  attr :deploy_tab, :string, required: true

  def site_deploy_tabs(assigns) do
    ~H"""
    <div class="p-5 border-b border-border">
      <p class="text-sm text-body mb-3">
        Choose your deployment environment:
      </p>
      <div class="grid grid-cols-2 md:grid-cols-5 gap-2">
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="debian-instructions"
          label="Debian/Ubuntu"
          icon="icon-os-debian"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="systemd-instructions"
          label="systemd"
          icon="ri-terminal-line"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="docker-instructions"
          label="Docker"
          icon="icon-docker"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="terraform-instructions"
          label="Terraform"
          icon="icon-terraform"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="custom-instructions"
          label="Custom"
          icon="ri-tools-line"
        />
      </div>
    </div>
    """
  end

  attr :deploy_tab, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  def deploy_tab_button(assigns) do
    ~H"""
    <button
      phx-click="deploy_tab_selected"
      phx-value-tab={@value}
      class={[
        "flex items-center justify-center gap-1.5 px-3 py-2 rounded text-xs font-medium border transition-colors",
        if(@deploy_tab == @value,
          do: "border-brand bg-brand-muted text-brand",
          else:
            "border-border text-body hover:text-heading hover:bg-raised"
        )
      ]}
    >
      <.icon name={@icon} class="w-3.5 h-3.5 shrink-0" />
      {@label}
    </button>
    """
  end

  attr :deploy_tab, :string, required: true
  attr :deploy_env, :any, default: nil

  def site_deploy_instructions(assigns) do
    ~H"""
    <.site_deploy_debian :if={@deploy_tab == "debian-instructions"} deploy_env={@deploy_env} />
    <.site_deploy_systemd :if={@deploy_tab == "systemd-instructions"} deploy_env={@deploy_env} />
    <.site_deploy_docker :if={@deploy_tab == "docker-instructions"} deploy_env={@deploy_env} />
    <.site_deploy_terraform
      :if={@deploy_tab == "terraform-instructions"}
      deploy_env={@deploy_env}
    />
    <.site_deploy_custom :if={@deploy_tab == "custom-instructions"} deploy_env={@deploy_env} />
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_docker(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-body">Run this command on your host:</p>
      <.code_block
        id="deploy-code-docker"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_docker_command(@deploy_env) %></.code_block>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_systemd(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-body">Install via systemd:</p>
      <.code_block
        id="deploy-code-systemd"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_systemd_command(@deploy_env) %></.code_block>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_debian(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-body">
        Step 1: Add the Firezone APT repository:
      </p>
      <.code_block
        id="deploy-code-debian-repo"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_apt_repository() %></.code_block>

      <p class="text-xs text-body">
        Step 2: Install the Firezone Gateway:
      </p>
      <.code_block
        id="deploy-code-debian-install"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_install() %></.code_block>

      <p class="text-xs text-body">
        Step 3: Authenticate the Firezone Gateway:
      </p>
      <.code_block
        id="deploy-code-debian-auth"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_authenticate() %></.code_block>

      <p class="text-xs text-body">
        Step 4: Use this token when prompted:
      </p>
      <.code_block
        id="deploy-code-debian-token"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_token(@deploy_env) %></.code_block>

      <p class="text-xs text-body">
        Step 5: You are now ready to manage the Gateway using the <code class="font-mono">firezone</code>
        CLI.
      </p>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_custom(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-body">
        Step 1: Download the latest binary for your architecture:
      </p>
      <p>
        <.website_link path="/changelog">Firezone changelog</.website_link>
      </p>

      <p class="text-xs text-body">
        Step 2: Set required environment variables:
      </p>
      <.code_block
        id="deploy-code-custom-env"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_manual_env(@deploy_env) %></.code_block>

      <p class="text-xs text-body">
        Step 3: Enable packet forwarding for IPv4 and IPv6:
      </p>
      <.code_block
        id="deploy-code-custom-forwarding"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_manual_forwarding() %></.code_block>

      <p class="text-xs text-body">
        Step 4: Enable masquerading for ethernet and Wi-Fi interfaces:
      </p>
      <.code_block
        id="deploy-code-custom-masquerading"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_manual_masquerading() %></.code_block>

      <p class="text-xs text-body">
        Step 5: Run the binary you downloaded:
      </p>
      <.code_block
        id="deploy-code-custom-run"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= "sudo ./firezone-gateway-<version>-<architecture>" %></.code_block>

      <p class="text-xs text-body">
        Make sure to save the <code class="font-mono">FIREZONE_TOKEN</code>
        shown above to a secure location before continuing. It won't be shown again.
      </p>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_terraform(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-body">
        Use `FIREZONE_TOKEN` in your Terraform-managed gateway environment:
      </p>
      <.code_block
        id="deploy-code-terraform"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_token(@deploy_env) %></.code_block>
      <p class="text-xs text-body">
        <.website_link path="/kb/automate">Terraform guides</.website_link>
      </p>
    </div>
    """
  end

  attr :resource_form, :any, default: nil
  attr :filters_dropdown_open, :boolean, required: true
  attr :active_protocols, :list, required: true
  attr :filter_ports, :map, required: true

  def site_add_resource_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <.site_add_resource_header />
      <.form
        :if={@resource_form}
        for={@resource_form}
        phx-submit="resource_submit"
        phx-change="resource_change"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <.resource_type_picker resource_form={@resource_form} />
          <.resource_primary_fields resource_form={@resource_form} />
          <.resource_dns_stack
            :if={"#{@resource_form[:type].value}" == "dns"}
            resource_form={@resource_form}
          />
          <.resource_filters_section
            filters_dropdown_open={@filters_dropdown_open}
            active_protocols={@active_protocols}
            filter_ports={@filter_ports}
          />
        </div>
        <.resource_form_actions />
      </.form>
    </div>
    """
  end

  def site_add_resource_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-heading">Add Resource</h2>
        <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_add_resource" />
      </div>
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_type_picker(assigns) do
    ~H"""
    <div>
      <span class="block text-xs font-medium text-body mb-1.5">
        Type <span class="text-error">*</span>
      </span>
      <ul class="grid w-full gap-3 grid-cols-3">
        <li>
          <.input
            id="panel-resource-form-type--dns"
            type="radio_button_group"
            field={@resource_form[:type]}
            value="dns"
            checked={to_string(@resource_form[:type].value) == "dns"}
            required
          />
          <label
            for="panel-resource-form-type--dns"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="ri-global-line" class="w-4 h-4 mr-1" /> DNS
              </div>
              <div class="w-full text-[10px]">By DNS address</div>
            </div>
          </label>
        </li>
        <li>
          <.input
            id="panel-resource-form-type--ip"
            type="radio_button_group"
            field={@resource_form[:type]}
            value="ip"
            checked={to_string(@resource_form[:type].value) == "ip"}
            required
          />
          <label
            for="panel-resource-form-type--ip"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="ri-server-line" class="w-4 h-4 mr-1" /> IP
              </div>
              <div class="w-full text-[10px]">By IP address</div>
            </div>
          </label>
        </li>
        <li>
          <.input
            id="panel-resource-form-type--cidr"
            type="radio_button_group"
            field={@resource_form[:type]}
            value="cidr"
            checked={to_string(@resource_form[:type].value) == "cidr"}
            required
          />
          <label
            for="panel-resource-form-type--cidr"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="ri-server-line" class="w-4 h-4 mr-1" /> CIDR
              </div>
              <div class="w-full text-[10px]">By CIDR range</div>
            </div>
          </label>
        </li>
      </ul>
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_primary_fields(assigns) do
    ~H"""
    <div>
      <label
        for={@resource_form[:address].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Address <span class="text-error">*</span>
      </label>
      <.input
        field={@resource_form[:address]}
        autocomplete="off"
        placeholder={
          cond do
            to_string(@resource_form[:type].value) == "dns" -> "gitlab.company.com"
            to_string(@resource_form[:type].value) == "cidr" -> "10.0.0.0/24"
            to_string(@resource_form[:type].value) == "ip" -> "10.3.2.1"
            true -> "First select a type above"
          end
        }
        disabled={is_nil(@resource_form[:type].value)}
        phx-debounce="300"
        required
        class="font-mono"
      />
    </div>
    <div>
      <label
        for={@resource_form[:address_description].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Address Description <span class="text-muted font-normal">(optional)</span>
      </label>
      <.input
        field={@resource_form[:address_description]}
        type="text"
        placeholder="Enter a description or URL"
        phx-debounce="300"
      />
      <p class="mt-1 text-xs text-subtle">
        Optional description or URL shown in Clients.
      </p>
    </div>
    <div>
      <label
        for={@resource_form[:name].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Name <span class="text-error">*</span>
      </label>
      <.input
        field={@resource_form[:name]}
        type="text"
        placeholder="Name this resource"
        phx-debounce="300"
        required
      />
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_dns_stack(assigns) do
    ~H"""
    <div>
      <.input
        id="panel-resource-form-ip-stack--dual"
        type="radio_button_group"
        field={@resource_form[:ip_stack]}
        value="dual"
        checked={
          "#{@resource_form[:ip_stack].value}" == "" or
            "#{@resource_form[:ip_stack].value}" == "dual"
        }
      />
      <.input
        id="panel-resource-form-ip-stack--ipv4"
        type="radio_button_group"
        field={@resource_form[:ip_stack]}
        value="ipv4_only"
        checked={"#{@resource_form[:ip_stack].value}" == "ipv4_only"}
      />
      <.input
        id="panel-resource-form-ip-stack--ipv6"
        type="radio_button_group"
        field={@resource_form[:ip_stack]}
        value="ipv6_only"
        checked={"#{@resource_form[:ip_stack].value}" == "ipv6_only"}
      />
      <span class="block text-xs font-medium text-body mb-1.5">
        IP Stack
      </span>
      <div class="inline-flex rounded border border-border overflow-hidden">
        <label
          for="panel-resource-form-ip-stack--dual"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-border first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "" or
                "#{@resource_form[:ip_stack].value}" == "dual",
              do: "bg-brand text-white",
              else:
                "bg-surface text-body hover:text-heading"
            )
          ]}
        >
          Both
        </label>
        <label
          for="panel-resource-form-ip-stack--ipv4"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-border first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "ipv4_only",
              do: "bg-brand text-white",
              else:
                "bg-surface text-body hover:text-heading"
            )
          ]}
        >
          IPv4
        </label>
        <label
          for="panel-resource-form-ip-stack--ipv6"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-border first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "ipv6_only",
              do: "bg-brand text-white",
              else:
                "bg-surface text-body hover:text-heading"
            )
          ]}
        >
          IPv6
        </label>
      </div>
      <p class="mt-1.5 text-xs text-body leading-snug">
        {case "#{@resource_form[:ip_stack].value}" do
          "ipv4_only" ->
            "Resolves only A records — clients connect over IPv4."

          "ipv6_only" ->
            "Resolves only AAAA records — clients connect over IPv6."

          _ ->
            "Resolves A and AAAA records — clients connect over IPv4 or IPv6, whichever is available."
        end}
      </p>
    </div>
    """
  end

  attr :filters_dropdown_open, :boolean, required: true
  attr :active_protocols, :list, required: true
  attr :filter_ports, :map, required: true

  def resource_filters_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <span class="block text-xs font-medium text-body">
          Traffic Restrictions <span class="font-normal text-subtle">(optional)</span>
        </span>
        <.resource_filters_dropdown
          filters_dropdown_open={@filters_dropdown_open}
          active_protocols={@active_protocols}
        />
      </div>
      <.resource_filters_empty_state :if={@active_protocols == []} />
      <div :if={@active_protocols != []} class="flex flex-col gap-2">
        <.resource_filter_row
          :for={protocol <- @active_protocols}
          protocol={protocol}
          ports={Map.get(@filter_ports, protocol, "")}
        />
      </div>
    </div>
    """
  end

  attr :filters_dropdown_open, :boolean, required: true
  attr :active_protocols, :list, required: true

  def resource_filters_dropdown(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_resource_filters_dropdown"
        class="inline-flex items-center gap-1 text-xs text-body hover:text-heading border border-border rounded px-2 py-1 bg-surface hover:bg-raised transition-colors"
      >
        <.icon name="ri-add-line" class="w-3 h-3" /> Add protocol
        <.icon name="ri-arrow-down-s-line" class="w-3 h-3" />
      </button>
      <div
        :if={@filters_dropdown_open}
        phx-click-away="close_resource_filters_dropdown"
        class="absolute right-0 top-full mt-1 z-20 bg-elevated border border-border rounded shadow-md min-w-[120px]"
      >
        <.resource_filter_dropdown_item :if={:tcp not in @active_protocols} protocol="tcp" />
        <.resource_filter_dropdown_item :if={:udp not in @active_protocols} protocol="udp" />
        <.resource_filter_dropdown_item :if={:icmp not in @active_protocols} protocol="icmp" />
        <div
          :if={Enum.sort(@active_protocols) == [:icmp, :tcp, :udp]}
          class="px-3 py-2 text-xs text-subtle"
        >
          All protocols added
        </div>
      </div>
    </div>
    """
  end

  attr :protocol, :string, required: true

  def resource_filter_dropdown_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="add_resource_filter"
      phx-value-protocol={@protocol}
      class="flex items-center w-full px-3 py-2 text-xs text-heading hover:bg-raised transition-colors"
    >
      {String.upcase(@protocol)}
    </button>
    """
  end

  def resource_filters_empty_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center rounded border border-dashed border-border px-4 py-5 text-xs text-subtle">
      No restrictions — all traffic is permitted
    </div>
    """
  end

  attr :protocol, :atom, required: true
  attr :ports, :string, required: true

  def resource_filter_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 rounded border border-border bg-surface px-3 py-2">
      <input type="hidden" name={"resource[filters][#{@protocol}][enabled]"} value="true" />
      <input type="hidden" name={"resource[filters][#{@protocol}][protocol]"} value={"#{@protocol}"} />
      <span class="w-10 shrink-0 text-xs font-medium text-heading uppercase">
        {@protocol}
      </span>
      <div :if={@protocol != :icmp} class="flex-1">
        <input
          type="text"
          name={"resource[filters][#{@protocol}][ports]"}
          value={@ports}
          placeholder="All ports"
          class="w-full px-3 py-2 text-sm rounded-md border font-mono bg-input text-heading placeholder:text-muted outline-none transition-colors border-input-border focus:border-border-focus focus:ring-1 focus:ring-border-focus/30"
        />
      </div>
      <span :if={@protocol == :icmp} class="flex-1 text-xs text-subtle italic">
        echo request/reply
      </span>
      <button
        type="button"
        phx-click="remove_resource_filter"
        phx-value-protocol={"#{@protocol}"}
        class="shrink-0 text-subtle hover:text-heading transition-colors"
        aria-label={"Remove #{@protocol} filter"}
      >
        <.icon name="ri-close-line" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  def resource_form_actions(assigns) do
    ~H"""
    <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
      <.button type="button" phx-click="close_add_resource" size="xs">
        Cancel
      </.button>
      <.button type="submit" style="primary" size="xs">
        Create Resource
      </.button>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :form, :any, default: nil

  def site_edit_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-heading">Edit Site</h2>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="cancel_site_edit_form" />
        </div>
      </div>
      <.form
        :if={@form}
        for={@form}
        phx-submit="submit_site_edit_form"
        phx-change="change_site_edit_form"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <div :if={@site.managed_by == :account}>
            <label
              for={@form[:name].id}
              class="block text-xs font-medium text-body mb-1.5"
            >
              Name <span class="text-error">*</span>
            </label>
            <.input
              field={@form[:name]}
              type="text"
              placeholder="Name of this site"
              phx-debounce="300"
              required
            />
          </div>
          <div>
            <.input
              field={@form[:health_threshold]}
              type="number"
              label="Health threshold"
              min="1"
            />
            <p class="mt-1.5 text-xs text-subtle">
              Minimum number of gateways that must be online for this site to be considered healthy.
            </p>
          </div>
        </div>
        <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
          <.button type="button" phx-click="cancel_site_edit_form" size="sm">
            Cancel
          </.button>
          <.button type="submit" style="primary" size="sm" class="font-medium">
            Save
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :status, :atom, required: true, values: [:healthy, :degraded, :offline]

  def site_status_badge(assigns) do
    ~H"""
    <.status_badge style={site_badge_style(@status)}>
      {Phoenix.Naming.humanize(@status)}
    </.status_badge>
    """
  end

  defp site_badge_style(:healthy), do: :success
  defp site_badge_style(:degraded), do: :warning
  defp site_badge_style(:offline), do: :neutral

  defp site_status(gateways, threshold) do
    online_count = Enum.count(gateways, & &1.online?)

    cond do
      online_count == 0 -> :offline
      online_count < threshold -> :degraded
      true -> :healthy
    end
  end

  defp gateway_token(env) do
    {"FIREZONE_TOKEN", value} = List.keyfind(env, "FIREZONE_TOKEN", 0)
    value
  end

  defp gateway_docker_command(env) do
    [
      "docker run -d",
      "--restart=unless-stopped",
      "--pull=always",
      "--health-cmd=\"ip link | grep tun-firezone\"",
      "--name=firezone-gateway",
      "--cap-add=NET_ADMIN",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env, fn {key, value} -> "--env #{key}=\"#{value}\"" end),
      "--env FIREZONE_NAME=$(hostname)",
      "--env RUST_LOG=info",
      "#{Portal.Config.fetch_env!(:portal, :docker_registry)}/gateway:1"
    ]
    |> List.flatten()
    |> Enum.join(" \\\n  ")
  end

  defp gateway_systemd_command(env) do
    """
    #{Enum.map_join(env, " \\\n", fn {key, value} -> "#{key}=\"#{value}\"" end)} \\
      bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)
    """
  end

  defp gateway_debian_apt_repository do
    """
    sudo mkdir --parents /etc/apt/keyrings
    wget -qO- https://artifacts.firezone.dev/apt/key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/firezone.gpg
    echo "deb [signed-by=/etc/apt/keyrings/firezone.gpg] https://artifacts.firezone.dev/apt/ stable main" | sudo tee /etc/apt/sources.list.d/firezone.list > /dev/null
    """
  end

  defp gateway_debian_install do
    """
    sudo apt update
    sudo apt install firezone-gateway
    """
  end

  defp gateway_debian_authenticate do
    """
    sudo firezone gateway authenticate
    """
  end

  defp gateway_manual_env(env) do
    """
    RUST_LOG=info
    #{Enum.map_join(env, "\n", fn {key, value} -> "#{key}=#{value}" end)}
    """
  end

  defp gateway_manual_forwarding do
    """
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sudo sysctl -w net.ipv6.conf.all.forwarding=1
    sudo sysctl -w net.ipv6.conf.default.forwarding=1
    """
  end

  defp gateway_manual_masquerading do
    """
    sudo iptables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo iptables -A FORWARD -i tun-firezone -j ACCEPT
    sudo iptables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo iptables -A FORWARD -o tun-firezone -j ACCEPT
    sudo iptables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || sudo iptables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    sudo iptables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || sudo iptables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    sudo ip6tables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo ip6tables -A FORWARD -i tun-firezone -j ACCEPT
    sudo ip6tables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo ip6tables -A FORWARD -o tun-firezone -j ACCEPT
    sudo ip6tables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || sudo ip6tables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    sudo ip6tables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || sudo ip6tables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    """
  end

  defp type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-dns text-badge-dns-text"

  defp type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-ip text-badge-ip-text"

  defp type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-cidr text-badge-cidr-text"

  defp type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-raised text-body"
end
