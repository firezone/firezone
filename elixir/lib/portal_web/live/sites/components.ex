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
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@open, do: "translate-x-0", else: "translate-x-full")
      ]}
    >
      <div :if={@open} class="flex flex-col h-full overflow-hidden">
        <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
          <h2 class="text-sm font-semibold text-[var(--text-primary)]">New Site</h2>
          <button
            phx-click="close_new_site_panel"
            class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <.icon name="ri-close-line" class="w-4 h-4" />
          </button>
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
                <p class="mt-1.5 text-xs text-[var(--text-tertiary)]">
                  Minimum number of gateways that must be online for this site to be considered healthy.
                </p>
              </div>
            </div>
            <div class="flex items-center justify-end gap-2 mt-6">
              <button
                type="button"
                phx-click="close_new_site_panel"
                class="px-3 py-1.5 text-sm rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={not @form.source.valid?}
                class="px-3 py-1.5 text-sm rounded bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                Create Site
              </button>
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
        |> assign(:online_count, Enum.count(assigns.gateways, & &1.online?))
        |> assign(:total_count, Map.get(assigns.gateway_counts, assigns.site.id, 0))
        |> assign(:status, site_status(assigns.gateways, assigns.site.health_threshold))
      else
        assigns
        |> assign(:online_count, 0)
        |> assign(:total_count, 0)
        |> assign(:status, :offline)
      end

    ~H"""
    <div
      id="site-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
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
          online_count={@online_count}
          resource_count={Map.get(@resources_counts, @site.id, 0)}
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
  attr :online_count, :integer, required: true
  attr :resource_count, :integer, required: true

  def site_panel_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <h2 class="text-sm font-semibold text-[var(--text-primary)]">{@site.name}</h2>
          </div>
          <p :if={@site.managed_by == :system} class="text-xs text-[var(--text-tertiary)] mt-0.5">
            system managed
          </p>
        </div>
        <div class="flex items-center gap-1.5 shrink-0">
          <button
            :if={@view == :gateways}
            phx-click="open_site_edit_form"
            class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
          >
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </button>
          <button
            phx-click="close_panel"
            class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <div class="flex items-center gap-5 mt-3 pt-3 border-t border-[var(--border)]">
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
            Status
          </span>
          <.status_badge status={@status} />
        </div>
        <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
            Gateways
          </span>
          <span class="text-xs font-semibold tabular-nums text-[var(--text-secondary)]">
            {@online_count}<span class="text-[var(--text-tertiary)] font-normal"> online / </span>
            {@site.health_threshold} <span class="text-[var(--text-tertiary)] font-normal"> required</span>
          </span>
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
    <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)] overflow-hidden">
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
    <div class="flex items-end gap-0 px-5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
      <button
        phx-click="switch_panel_tab"
        phx-value-tab="gateways"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :gateways,
            do: "border-[var(--brand)] text-[var(--brand)]",
            else:
              "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
          )
        ]}
      >
        Gateways
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :gateways,
            do: "bg-[var(--brand-muted)] text-[var(--brand)]",
            else: "bg-[var(--surface-raised)] text-[var(--text-tertiary)]"
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
            do: "border-[var(--brand)] text-[var(--brand)]",
            else:
              "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
          )
        ]}
      >
        Resources
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :resources,
            do: "bg-[var(--brand-muted)] text-[var(--brand)]",
            else: "bg-[var(--surface-raised)] text-[var(--text-tertiary)]"
          )
        ]}>
          {@resource_count}
        </span>
      </button>
      <div class="ml-auto pb-2 flex items-center gap-2">
        <button
          :if={@tab == :gateways}
          phx-click="deploy_gateway"
          class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          <.icon name="ri-add-line" class="w-3 h-3" /> Deploy gateway
        </button>
        <button
          :if={@tab == :resources and @site.managed_by == :account}
          phx-click="add_resource"
          class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          <.icon name="ri-add-line" class="w-3 h-3" /> Add resource
        </button>
        <button
          :if={@tab == :gateways and not @show_all_gateways}
          phx-click="show_all_gateways"
          class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          View all <.icon name="ri-arrow-right-line" class="w-3 h-3" />
        </button>
        <button
          :if={@tab == :gateways and @show_all_gateways}
          phx-click="show_online_gateways"
          class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          Online only
        </button>
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
          class="border-b border-[var(--border)] hover:bg-[var(--surface-raised)] cursor-pointer transition-colors group"
        >
          <div class="flex items-center gap-3 px-5 py-3">
            <div class="flex items-center justify-center w-7 h-7 rounded border border-[var(--border-strong)] bg-[var(--surface-raised)] shrink-0">
              <svg
                class="w-3.5 h-3.5 text-[var(--text-tertiary)]"
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
              <p class="font-mono text-sm font-medium text-[var(--text-primary)] truncate group-hover:text-[var(--brand)] transition-colors">
                {gateway.name}
              </p>
              <p
                :if={gateway.latest_session}
                class="font-mono text-xs text-[var(--text-tertiary)] mt-0.5"
              >
                {gateway.latest_session.remote_ip}
              </p>
            </div>
            <span :if={gateway.online?} class="inline-flex items-center gap-1.5 shrink-0">
              <span class="relative flex items-center justify-center w-1.5 h-1.5">
                <span class="absolute inline-flex rounded-full opacity-60 animate-ping w-1.5 h-1.5 bg-[var(--status-active)]">
                </span>
                <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-active)]">
                </span>
              </span>
            </span>
            <span :if={not gateway.online?} class="inline-flex items-center gap-1.5 shrink-0">
              <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-neutral)]">
              </span>
            </span>
            <.icon
              name="ri-arrow-right-s-line"
              class={"w-4 h-4 text-[var(--text-tertiary)] transition-transform shrink-0#{if @expanded_gateway_id == gateway.id, do: " rotate-90", else: ""}"}
            />
          </div>
          <div
            :if={@expanded_gateway_id == gateway.id}
            class="px-5 pb-3 pt-1 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5"
          >
            <span class="text-xs text-[var(--text-tertiary)]">Last started</span>
            <span class="text-xs text-[var(--text-primary)]">
              <.relative_datetime
                datetime={gateway.latest_session && gateway.latest_session.inserted_at}
                popover={false}
              />
            </span>
            <span class="text-xs text-[var(--text-tertiary)]">Remote IP</span>
            <span class="font-mono text-xs text-[var(--text-primary)]">
              {gateway.latest_session && gateway.latest_session.remote_ip}
            </span>
            <span class="text-xs text-[var(--text-tertiary)]">Version</span>
            <span class="font-mono text-xs text-[var(--text-primary)]">
              {gateway.latest_session && gateway.latest_session.version}
            </span>
            <span class="text-xs text-[var(--text-tertiary)]">User agent</span>
            <span class="font-mono text-xs text-[var(--text-primary)] break-all">
              {gateway.latest_session && gateway.latest_session.user_agent}
            </span>
            <span class="text-xs text-[var(--text-tertiary)]">Tunnel IPv4</span>
            <span class="font-mono text-xs text-[var(--text-primary)]">
              {gateway.ipv4}
            </span>
            <span class="text-xs text-[var(--text-tertiary)]">Tunnel IPv6</span>
            <span class="font-mono text-xs text-[var(--text-primary)]">
              {gateway.ipv6}
            </span>
          </div>
        </li>
      </ul>
      <div
        :if={@gateways == [] and Map.get(@gateway_counts, @site.id, 0) == 0}
        class="flex flex-col items-center justify-center gap-3 py-16"
      >
        <p class="text-sm text-[var(--text-tertiary)]">No gateways deployed to this site.</p>
        <button
          phx-click="deploy_gateway"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          <.icon name="ri-add-line" class="w-3.5 h-3.5" /> Deploy a gateway
        </button>
      </div>
      <div
        :if={@gateways == [] and Map.get(@gateway_counts, @site.id, 0) > 0}
        class="flex items-center justify-center py-16"
      >
        <p class="text-sm text-[var(--text-tertiary)]">
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
        <li :for={resource <- @resources} class="border-b border-[var(--border)]">
          <.link
            navigate={~p"/#{@account}/resources/#{resource.id}"}
            class="flex items-center gap-3 px-5 py-3 hover:bg-[var(--surface-raised)] transition-colors group"
          >
            <span class={type_badge_class(resource.type)}>
              {resource.type}
            </span>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-[var(--text-primary)] truncate group-hover:text-[var(--brand)] transition-colors">
                {resource.name}
              </p>
              <p class="font-mono text-xs text-[var(--text-tertiary)] mt-0.5">
                {resource.address}
              </p>
            </div>
          </.link>
        </li>
      </ul>
      <div :if={@resources == []} class="flex flex-col items-center justify-center gap-3 py-16">
        <p class="text-sm text-[var(--text-tertiary)]">No resources assigned to this site.</p>
        <button
          :if={@site.managed_by == :account}
          phx-click="add_resource"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          <.icon name="ri-add-line" class="w-3.5 h-3.5" /> Add a resource
        </button>
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
      <div :if={@site.managed_by == :account} class="border-t border-[var(--border)]"></div>
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
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
        Details
      </h3>
      <dl class="space-y-2.5">
        <div>
          <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Name</dt>
          <dd class="text-xs text-[var(--text-secondary)] truncate" title={@site.name}>
            {@site.name}
          </dd>
        </div>
        <div>
          <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Health threshold</dt>
          <dd class="text-xs text-[var(--text-secondary)]">
            {@site.health_threshold}
          </dd>
        </div>
        <div>
          <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">ID</dt>
          <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
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
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
        Danger Zone
      </h3>
      <button
        :if={not @confirm_delete_site}
        type="button"
        phx-click="confirm_delete_site"
        class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
      >
        Delete site
      </button>
      <div
        :if={@confirm_delete_site}
        class="rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)] p-3 space-y-3"
      >
        <p class="text-xs text-[var(--status-error)]">
          Delete this site? Gateways and resources will be detached.
        </p>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="cancel_delete_site"
            class="px-2.5 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="delete_site"
            class="px-2.5 py-1 text-xs rounded bg-[var(--status-error)] text-white hover:opacity-90 transition-opacity"
          >
            Delete site
          </button>
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
      <div class="shrink-0 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-between gap-4">
        <p class="text-xs text-[var(--text-tertiary)]">
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
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-[var(--text-primary)]">Deploy a Gateway</h2>
        <button
          phx-click="close_deploy"
          class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          title="Close (Esc)"
        >
          <.icon name="ri-close-line" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :deploy_tab, :string, required: true

  def site_deploy_tabs(assigns) do
    ~H"""
    <div class="p-5 border-b border-[var(--border)]">
      <p class="text-sm text-[var(--text-secondary)] mb-3">
        Choose your deployment environment:
      </p>
      <div class="grid grid-cols-2 md:grid-cols-5 gap-2">
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="debian-instructions"
          label="Debian/Ubuntu"
          icon="os-debian"
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
          icon="docker"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="terraform-instructions"
          label="Terraform"
          icon="terraform"
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
          do: "border-[var(--brand)] bg-[var(--brand-muted)] text-[var(--brand)]",
          else:
            "border-[var(--border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)]"
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
    <.site_deploy_debian :if={@deploy_tab == "debian-instructions"} />
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
      <p class="text-xs text-[var(--text-secondary)]">Run this command on your host:</p>
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
      <p class="text-xs text-[var(--text-secondary)]">Install via systemd:</p>
      <.code_block
        id="deploy-code-systemd"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_systemd_command(@deploy_env) %></.code_block>
    </div>
    """
  end

  def site_deploy_debian(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-[var(--text-secondary)]">
        Add the Firezone APT repository:
      </p>
      <.code_block
        id="deploy-code-debian-repo"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_apt_repository() %></.code_block>

      <p class="text-xs text-[var(--text-secondary)]">
      Install the Firezone Gateway
      </p>
      <.code_block
        id="deploy-code-debian-install"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_install() %></.code_block>

      <p class="text-xs text-[var(--text-secondary)]">
      Launch the Firezone Gateway:
      </p>
      <.code_block
        id="deploy-code-debian-auth"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_authenticate() %></.code_block>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_custom(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-[var(--text-secondary)]">
        Set the <code class="font-mono">FIREZONE_TOKEN</code>
        environment variable and run the gateway binary directly:
      </p>
      <.code_block
        id="deploy-code-custom"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_token(@deploy_env) %></.code_block>
      <p class="text-xs text-[var(--text-secondary)]">
        <.website_link path="/kb/deploy/gateways">Gateway deployment guides</.website_link>
      </p>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_terraform(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-[var(--text-secondary)]">
        Use `FIREZONE_TOKEN` in your Terraform-managed gateway environment:
      </p>
      <.code_block
        id="deploy-code-terraform"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_token(@deploy_env) %></.code_block>
      <p class="text-xs text-[var(--text-secondary)]">
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
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-[var(--text-primary)]">Add Resource</h2>
        <button
          phx-click="close_add_resource"
          class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          title="Close (Esc)"
        >
          <.icon name="ri-close-line" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_type_picker(assigns) do
    ~H"""
    <div>
      <span class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
        Type <span class="text-[var(--status-error)]">*</span>
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
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
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Address <span class="text-[var(--status-error)]">*</span>
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
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Address Description <span class="text-[var(--text-muted)] font-normal">(optional)</span>
      </label>
      <.input
        field={@resource_form[:address_description]}
        type="text"
        placeholder="Enter a description or URL"
        phx-debounce="300"
      />
      <p class="mt-1 text-xs text-[var(--text-tertiary)]">
        Optional description or URL shown in Clients.
      </p>
    </div>
    <div>
      <label
        for={@resource_form[:name].id}
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Name <span class="text-[var(--status-error)]">*</span>
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
      <span class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
        IP Stack
      </span>
      <div class="inline-flex rounded border border-[var(--border)] overflow-hidden">
        <label
          for="panel-resource-form-ip-stack--dual"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-[var(--border)] first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "" or
                "#{@resource_form[:ip_stack].value}" == "dual",
              do: "bg-[var(--brand)] text-white",
              else:
                "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          Both
        </label>
        <label
          for="panel-resource-form-ip-stack--ipv4"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-[var(--border)] first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "ipv4_only",
              do: "bg-[var(--brand)] text-white",
              else:
                "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          IPv4
        </label>
        <label
          for="panel-resource-form-ip-stack--ipv6"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-[var(--border)] first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "ipv6_only",
              do: "bg-[var(--brand)] text-white",
              else:
                "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          IPv6
        </label>
      </div>
      <p class="mt-1.5 text-xs text-[var(--text-secondary)] leading-snug">
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
        <span class="block text-xs font-medium text-[var(--text-secondary)]">
          Traffic Restrictions <span class="font-normal text-[var(--text-tertiary)]">(optional)</span>
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
        class="inline-flex items-center gap-1 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] border border-[var(--border)] rounded px-2 py-1 bg-[var(--surface)] hover:bg-[var(--surface-raised)] transition-colors"
      >
        <.icon name="ri-add-line" class="w-3 h-3" /> Add protocol
        <.icon name="ri-arrow-down-s-line" class="w-3 h-3" />
      </button>
      <div
        :if={@filters_dropdown_open}
        phx-click-away="close_resource_filters_dropdown"
        class="absolute right-0 top-full mt-1 z-20 bg-[var(--surface-overlay)] border border-[var(--border)] rounded shadow-md min-w-[120px]"
      >
        <.resource_filter_dropdown_item :if={:tcp not in @active_protocols} protocol="tcp" />
        <.resource_filter_dropdown_item :if={:udp not in @active_protocols} protocol="udp" />
        <.resource_filter_dropdown_item :if={:icmp not in @active_protocols} protocol="icmp" />
        <div
          :if={Enum.sort(@active_protocols) == [:icmp, :tcp, :udp]}
          class="px-3 py-2 text-xs text-[var(--text-tertiary)]"
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
      class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
    >
      {String.upcase(@protocol)}
    </button>
    """
  end

  def resource_filters_empty_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center rounded border border-dashed border-[var(--border)] px-4 py-5 text-xs text-[var(--text-tertiary)]">
      No restrictions — all traffic is permitted
    </div>
    """
  end

  attr :protocol, :atom, required: true
  attr :ports, :string, required: true

  def resource_filter_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 rounded border border-[var(--border)] bg-[var(--surface)] px-3 py-2">
      <input type="hidden" name={"resource[filters][#{@protocol}][enabled]"} value="true" />
      <input type="hidden" name={"resource[filters][#{@protocol}][protocol]"} value={"#{@protocol}"} />
      <span class="w-10 shrink-0 text-xs font-medium text-[var(--text-primary)] uppercase">
        {@protocol}
      </span>
      <div :if={@protocol != :icmp} class="flex-1">
        <input
          type="text"
          name={"resource[filters][#{@protocol}][ports]"}
          value={@ports}
          placeholder="All ports"
          class="w-full px-3 py-2 text-sm rounded-md border font-mono bg-[var(--control-bg)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none transition-colors border-[var(--control-border)] focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30"
        />
      </div>
      <span :if={@protocol == :icmp} class="flex-1 text-xs text-[var(--text-tertiary)] italic">
        echo request/reply
      </span>
      <button
        type="button"
        phx-click="remove_resource_filter"
        phx-value-protocol={"#{@protocol}"}
        class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
        aria-label={"Remove #{@protocol} filter"}
      >
        <.icon name="ri-close-line" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  def resource_form_actions(assigns) do
    ~H"""
    <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
      <button
        type="button"
        phx-click="close_add_resource"
        class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
      >
        Cancel
      </button>
      <button
        type="submit"
        class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
      >
        Create Resource
      </button>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :form, :any, default: nil

  def site_edit_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit Site</h2>
          <button
            phx-click="cancel_site_edit_form"
            class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <.icon name="ri-close-line" class="w-4 h-4" />
          </button>
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
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Name <span class="text-[var(--status-error)]">*</span>
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
            <p class="mt-1.5 text-xs text-[var(--text-tertiary)]">
              Minimum number of gateways that must be online for this site to be considered healthy.
            </p>
          </div>
        </div>
        <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
          <button
            type="button"
            phx-click="cancel_site_edit_form"
            class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
          >
            Save
          </button>
        </div>
      </.form>
    </div>
    """
  end

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

  defp type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-dns-bg)] text-[var(--badge-dns-text)]"

  defp type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-ip-bg)] text-[var(--badge-ip-text)]"

  defp type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-cidr-bg)] text-[var(--badge-cidr-text)]"

  defp type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--surface-raised)] text-[var(--text-secondary)]"
end
