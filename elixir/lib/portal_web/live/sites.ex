defmodule PortalWeb.Sites do
  use PortalWeb, :live_view
  import PortalWeb.Resources.Components
  alias Portal.Presence
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Presence.Gateways.Account.subscribe(socket.assigns.account.id)
    end

    internet_resource = Database.get_internet_resource(socket.assigns.subject)
    sites = Database.list_all_sites(socket.assigns.subject)
    site_ids = Enum.map(sites, & &1.id)

    internet_site = internet_resource && internet_resource.site

    all_site_ids =
      if internet_site,
        do: [internet_site.id | site_ids],
        else: site_ids

    resources_counts = Database.count_resources_by_site(site_ids, socket.assigns.subject)
    policies_counts = Database.count_policies_by_site(all_site_ids, socket.assigns.subject)
    gateway_counts = Database.count_gateways_by_site(all_site_ids, socket.assigns.subject)

    socket =
      socket
      |> assign(page_title: "Sites")
      |> assign(sites: sites)
      |> assign(resources_counts: resources_counts)
      |> assign(policies_counts: policies_counts)
      |> assign(gateway_counts: gateway_counts)
      |> assign(internet_resource: internet_resource)
      |> assign(internet_site: internet_site)
      |> assign(
        selected_site: nil,
        panel_tab: :gateways,
        panel_gateways: [],
        panel_resources: [],
        panel_show_all_gateways: false,
        panel_view: :gateways,
        deploy_env: nil,
        deploy_tab: "docker-instructions",
        deploy_connected?: false,
        deploy_token: nil,
        resource_form: nil,
        resource_name_changed?: false,
        resource_form_filters_dropdown_open: false,
        resource_form_active_protocols: [],
        confirm_delete_site: false,
        site_edit_form: nil,
        new_site_panel: false,
        new_site_form: nil,
        expanded_gateway_id: nil
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :show}} = socket) do
    case Database.get_site(id, socket.assigns.subject) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}

      site ->
        {:noreply, assign(socket, site_panel_assigns(site, params, socket))}
    end
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :edit}} = socket) do
    case Database.get_site(id, socket.assigns.subject) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}

      site ->
        changeset = Database.change_site(site)

        {:noreply,
         assign(
           socket,
           Keyword.merge(
             site_panel_assigns(site, params, socket),
             panel_view: :edit_site,
             site_edit_form: to_form(changeset)
           )
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, site_panel_reset_assigns())}
  end

  defp site_panel_assigns(site, params, socket) do
    gateways =
      site.id
      |> Database.list_gateways_for_site(socket.assigns.subject)
      |> Presence.Gateways.preload_gateways_presence()
      |> Enum.filter(& &1.online?)

    resources =
      if site.managed_by == :account do
        Database.list_resources_for_site(site.id, socket.assigns.subject)
      else
        []
      end

    [
      selected_site: site,
      panel_tab: String.to_existing_atom(Map.get(params, "tab", "gateways")),
      panel_gateways: gateways,
      panel_resources: resources,
      panel_show_all_gateways: false,
      panel_view: :gateways,
      deploy_env: nil,
      deploy_tab: "docker-instructions",
      deploy_connected?: false,
      deploy_token: nil,
      resource_form: nil,
      resource_name_changed?: false,
      resource_form_filters_dropdown_open: false,
      resource_form_active_protocols: [],
      confirm_delete_site: false,
      site_edit_form: nil,
      new_site_panel: false,
      new_site_form: nil,
      expanded_gateway_id: nil
    ]
  end

  defp site_panel_reset_assigns do
    [
      selected_site: nil,
      panel_tab: :gateways,
      panel_gateways: [],
      panel_resources: [],
      panel_show_all_gateways: false,
      panel_view: :gateways,
      deploy_env: nil,
      deploy_tab: "docker-instructions",
      deploy_connected?: false,
      deploy_token: nil,
      resource_form: nil,
      resource_name_changed?: false,
      resource_form_filters_dropdown_open: false,
      resource_form_active_protocols: [],
      confirm_delete_site: false,
      site_edit_form: nil,
      new_site_panel: false,
      new_site_form: nil,
      expanded_gateway_id: nil
    ]
  end

  def render(assigns) do
    ~H"""
    <div
      class="relative flex flex-col h-full overflow-hidden"
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <.page_header>
        <:icon>
          <.icon name="remix-map-pin-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Sites</:title>
        <:description>
          Logical groupings of gateways - typically mapped to a network location or cloud region.
        </:description>
        <:action>
          <.docs_action path="/deploy/sites" />
          <.button style="primary" icon="remix-add-line" phx-click="open_new_site_panel">
            New Site
          </.button>
        </:action>
        <:filters>
          <% all_sites = @sites ++ if(@internet_site, do: [@internet_site], else: [])

          healthy_count =
            Enum.count(all_sites, &(compute_site_status(&1.id, &1.health_threshold) == :healthy))

          degraded_count =
            Enum.count(all_sites, &(compute_site_status(&1.id, &1.health_threshold) == :degraded))

          offline_count =
            Enum.count(all_sites, &(compute_site_status(&1.id, &1.health_threshold) == :offline)) %>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {length(all_sites)}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="relative flex items-center justify-center w-1.5 h-1.5">
              <span class="absolute inline-flex rounded-full opacity-60 animate-ping w-1.5 h-1.5 bg-[var(--status-active)]">
              </span>
              <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-active)]">
              </span>
            </span>
            Healthy {healthy_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-warn)]">
            </span>
            Degraded {degraded_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-neutral)]">
            </span>
            Offline {offline_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 overflow-auto overflow-x-auto">
        <table class="w-full text-sm border-collapse">
          <thead class="sticky top-0 z-10 bg-[var(--surface-raised)]">
            <tr class="border-b border-[var(--border-strong)]">
              <th class="py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Site
              </th>
              <th class="w-36 py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Gateways
              </th>
              <th class="w-28 py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Resources
              </th>
              <th class="w-28 py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Status
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :if={@internet_site}
              class={[
                "border-b border-[var(--border)] cursor-pointer transition-colors group border-l-4",
                if(not is_nil(@selected_site) and @selected_site.id == @internet_site.id,
                  do: "bg-[var(--brand-muted)] border-l-[var(--brand)]",
                  else:
                    "hover:bg-[var(--surface-raised)] border-l-transparent bg-violet-50/60 dark:bg-violet-950/20"
                )
              ]}
              phx-click="select_site"
              phx-value-id={@internet_site.id}
            >
              <td class="px-4 py-3">
                <div class="flex items-center gap-2">
                  <svg
                    class="w-4 h-4 shrink-0 text-violet-500"
                    viewBox="0 0 16 16"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.25"
                    stroke-linecap="round"
                  >
                    <circle cx="8" cy="8" r="6.5" />
                    <path d="M8 1.5c-2 3-2 10 0 13M8 1.5c2 3 2 10 0 13M1.5 8h13" />
                  </svg>
                  <div class={[
                    "font-medium transition-colors",
                    if(not is_nil(@selected_site) and @selected_site.id == @internet_site.id,
                      do: "text-[var(--brand)]",
                      else: "text-[var(--text-primary)] group-hover:text-[var(--brand)]"
                    )
                  ]}>
                    Internet Resource
                  </div>
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-200/70 text-violet-700 dark:bg-violet-900/40 dark:text-violet-300">
                    system
                  </span>
                </div>
                <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">
                  {@internet_site.id}
                </div>
              </td>
              <td class="px-4 py-3">
                <% online = gateway_online_count(@internet_site.id) %>
                <span class="text-sm text-[var(--text-secondary)] tabular-nums">
                  {online}<span class="text-[var(--text-muted)]">/{@internet_site.health_threshold}</span>
                  <span class="ml-1.5 text-[10px] text-[var(--text-muted)]">online</span>
                </span>
              </td>
              <td class="px-4 py-3">
                <span class="tabular-nums text-[var(--text-secondary)]">
                  {Map.get(@policies_counts, @internet_site.id, 0)}
                </span>
              </td>
              <td class="px-4 py-3">
                <.status_badge status={
                  compute_site_status(@internet_site.id, @internet_site.health_threshold)
                } />
              </td>
            </tr>
            <tr
              :for={site <- @sites}
              class={[
                "border-b border-[var(--border)] cursor-pointer transition-colors group border-l-4",
                if(not is_nil(@selected_site) and @selected_site.id == site.id,
                  do: "bg-[var(--brand-muted)] border-l-[var(--brand)]",
                  else: "hover:bg-[var(--surface-raised)] border-l-transparent"
                )
              ]}
              phx-click="select_site"
              phx-value-id={site.id}
            >
              <td class="px-4 py-3">
                <div class={[
                  "font-medium transition-colors",
                  if(not is_nil(@selected_site) and @selected_site.id == site.id,
                    do: "text-[var(--brand)]",
                    else: "text-[var(--text-primary)] group-hover:text-[var(--brand)]"
                  )
                ]}>
                  {site.name}
                </div>
                <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">
                  {site.id}
                </div>
              </td>
              <td class="px-4 py-3">
                <% online = gateway_online_count(site.id) %>
                <span class="text-sm text-[var(--text-secondary)] tabular-nums">
                  {online}<span class="text-[var(--text-muted)]">/{site.health_threshold}</span>
                  <span class="ml-1.5 text-[10px] text-[var(--text-muted)]">online</span>
                </span>
              </td>
              <td class="px-4 py-3">
                <span class="tabular-nums text-[var(--text-secondary)]">
                  {Map.get(@resources_counts, site.id, 0)}
                </span>
              </td>
              <td class="px-4 py-3">
                <.status_badge status={compute_site_status(site.id, site.health_threshold)} />
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :if={@sites == [] and is_nil(@internet_site)}
          class="flex flex-1 items-center justify-center p-8"
        >
          <span class="text-sm text-[var(--text-tertiary)]">
            No sites to display.
            <button class={link_style()} phx-click="open_new_site_panel">Add a site</button>
            to start deploying gateways and adding resources.
          </span>
        </div>
      </div>

      <%!-- Right-hand detail panel --%>
      <.site_panel
        site={@selected_site}
        expanded_gateway_id={@expanded_gateway_id}
        panel_tab={@panel_tab}
        panel_view={@panel_view}
        panel_show_all_gateways={@panel_show_all_gateways}
        gateways={@panel_gateways}
        resources={@panel_resources}
        resources_counts={@resources_counts}
        policies_counts={@policies_counts}
        gateway_counts={@gateway_counts}
        account={@account}
        deploy_env={@deploy_env}
        deploy_tab={@deploy_tab}
        deploy_connected?={@deploy_connected?}
        resource_form={@resource_form}
        resource_form_filters_dropdown_open={@resource_form_filters_dropdown_open}
        resource_form_active_protocols={@resource_form_active_protocols}
        confirm_delete_site={@confirm_delete_site}
        site_edit_form={@site_edit_form}
      />

      <.new_site_panel open={@new_site_panel} form={@new_site_form} />
    </div>
    """
  end

  # ---- New Site panel ----

  attr :open, :boolean, required: true
  attr :form, :any, default: nil

  defp new_site_panel(assigns) do
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
            <.icon name="remix-close-line" class="w-4 h-4" />
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

  # ---- Right-hand panel ----

  attr :site, :any, required: true
  attr :expanded_gateway_id, :string, default: nil
  attr :panel_tab, :atom, required: true
  attr :panel_view, :atom, required: true
  attr :panel_show_all_gateways, :boolean, required: true
  attr :gateways, :list, required: true
  attr :resources, :list, required: true
  attr :resources_counts, :map, required: true
  attr :policies_counts, :map, required: true
  attr :gateway_counts, :map, required: true
  attr :account, :any, required: true
  attr :deploy_env, :any, required: true
  attr :deploy_tab, :string, required: true
  attr :deploy_connected?, :boolean, required: true
  attr :resource_form, :any, required: true
  attr :resource_form_filters_dropdown_open, :boolean, required: true
  attr :resource_form_active_protocols, :list, required: true
  attr :confirm_delete_site, :boolean, required: true
  attr :site_edit_form, :any, required: true

  defp site_panel(assigns) do
    filter_ports =
      if assigns.resource_form do
        assigns.resource_form.source
        |> Ecto.Changeset.get_field(:filters, [])
        |> Map.new(fn f -> {f.protocol, Enum.join(f.ports, ", ")} end)
      else
        %{}
      end

    assigns = assign(assigns, :filter_ports, filter_ports)

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
        <% online_count = Enum.count(@gateways, & &1.online?)
        total_count = Map.get(@gateway_counts, @site.id, 0)

        status =
          cond do
            online_count == 0 -> :offline
            online_count < @site.health_threshold -> :degraded
            true -> :healthy
          end %>
        <%!-- Panel header --%>
        <div
          :if={@panel_view != :edit_site}
          class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <h2 class="text-sm font-semibold text-[var(--text-primary)]">{@site.name}</h2>
                <.status_badge status={status} />
              </div>
              <p
                :if={@site.managed_by == :system}
                class="text-xs text-[var(--text-tertiary)] mt-0.5"
              >
                system managed
              </p>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <button
                :if={@panel_view == :gateways}
                phx-click="open_site_edit_form"
                class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-pencil-line" class="w-3.5 h-3.5" /> Edit
              </button>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="remix-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <%!-- Stat strip --%>
          <div class="flex items-center gap-5 mt-3 pt-3 border-t border-[var(--border)]">
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Gateways
              </span>
              <span class="text-xs font-semibold tabular-nums text-[var(--text-primary)]">
                {online_count}<span class="text-[var(--text-muted)] font-normal">/{@site.health_threshold}</span>
              </span>
              <span class="text-[10px] text-[var(--text-muted)]">online</span>
            </div>
            <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Resources
              </span>
              <span class="text-xs font-semibold tabular-nums text-[var(--text-primary)]">
                {Map.get(@resources_counts, @site.id, 0)}
              </span>
            </div>
          </div>
        </div>
        <%!-- Tab bar + content (gateways/resources view) --%>
        <div
          :if={@panel_view == :gateways}
          class="flex flex-1 min-h-0 divide-x divide-[var(--border)] overflow-hidden"
        >
          <div class="flex-1 flex flex-col overflow-hidden">
            <div class="flex items-end gap-0 px-5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
              <button
                phx-click="switch_panel_tab"
                phx-value-tab="gateways"
                class={[
                  "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
                  if(@panel_tab == :gateways,
                    do: "border-[var(--brand)] text-[var(--brand)]",
                    else:
                      "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
                  )
                ]}
              >
                Gateways
                <span class={[
                  "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
                  if(@panel_tab == :gateways,
                    do: "bg-[var(--brand-muted)] text-[var(--brand)]",
                    else: "bg-[var(--surface-raised)] text-[var(--text-tertiary)]"
                  )
                ]}>
                  {total_count}
                </span>
              </button>
              <button
                :if={@site.managed_by == :account}
                phx-click="switch_panel_tab"
                phx-value-tab="resources"
                class={[
                  "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
                  if(@panel_tab == :resources,
                    do: "border-[var(--brand)] text-[var(--brand)]",
                    else:
                      "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
                  )
                ]}
              >
                Resources
                <span class={[
                  "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
                  if(@panel_tab == :resources,
                    do: "bg-[var(--brand-muted)] text-[var(--brand)]",
                    else: "bg-[var(--surface-raised)] text-[var(--text-tertiary)]"
                  )
                ]}>
                  {Map.get(@resources_counts, @site.id, 0)}
                </span>
              </button>
              <div class="ml-auto pb-2 flex items-center gap-2">
                <button
                  :if={@panel_tab == :gateways}
                  phx-click="deploy_gateway"
                  class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="remix-add-line" class="w-3 h-3" /> Deploy gateway
                </button>
                <button
                  :if={@panel_tab == :resources and @site.managed_by == :account}
                  phx-click="add_resource"
                  class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="remix-add-line" class="w-3 h-3" /> Add resource
                </button>
                <button
                  :if={@panel_tab == :gateways and not @panel_show_all_gateways}
                  phx-click="show_all_gateways"
                  class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  View all <.icon name="remix-arrow-right-line" class="w-3 h-3" />
                </button>
                <button
                  :if={@panel_tab == :gateways and @panel_show_all_gateways}
                  phx-click="show_online_gateways"
                  class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  Online only
                </button>
              </div>
            </div>
            <%!-- Gateways tab --%>
            <div :if={@panel_tab == :gateways} class="flex-1 overflow-y-auto">
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
                      name="remix-arrow-right-s-line"
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
                      {gateway.ipv4_address && gateway.ipv4_address.address}
                    </span>

                    <span class="text-xs text-[var(--text-tertiary)]">Tunnel IPv6</span>
                    <span class="font-mono text-xs text-[var(--text-primary)]">
                      {gateway.ipv6_address && gateway.ipv6_address.address}
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
                  <.icon name="remix-add-line" class="w-3.5 h-3.5" /> Deploy a gateway
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
            <%!-- Resources tab --%>
            <div :if={@panel_tab == :resources} class="flex-1 overflow-y-auto">
              <ul>
                <li
                  :for={resource <- @resources}
                  class="border-b border-[var(--border)]"
                >
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
              <div
                :if={@resources == []}
                class="flex flex-col items-center justify-center gap-3 py-16"
              >
                <p class="text-sm text-[var(--text-tertiary)]">No resources assigned to this site.</p>
                <button
                  :if={@site.managed_by == :account}
                  phx-click="add_resource"
                  class="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="remix-add-line" class="w-3.5 h-3.5" /> Add a resource
                </button>
              </div>
            </div>
          </div>
          <%!-- Details + Danger Zone sidebar --%>
          <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
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
            <div :if={@site.managed_by == :account} class="border-t border-[var(--border)]"></div>
            <section :if={@site.managed_by == :account}>
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
                class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
              >
                <p class="text-xs font-medium text-[var(--status-error)] mb-1">Delete this site?</p>
                <p class="text-xs text-[var(--status-error)]/70 mb-3">
                  All gateways, tokens, and resources will be permanently removed.
                </p>
                <div class="flex items-center gap-1.5">
                  <button
                    type="button"
                    phx-click="cancel_delete_site"
                    class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    phx-click="delete_site"
                    class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </section>
          </div>
        </div>
        <%!-- Deploy gateway view --%>
        <div :if={@panel_view == :deploy} class="flex flex-1 min-h-0 flex-col overflow-hidden">
          <%!-- Deploy header row --%>
          <div class="flex items-center gap-2 px-5 py-2.5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
            <button
              phx-click="close_deploy"
              class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface)] transition-colors"
              title="Back"
            >
              <.icon name="remix-arrow-left-line" class="w-3.5 h-3.5" />
            </button>
            <span class="text-xs font-semibold text-[var(--text-primary)]">Deploy a Gateway</span>
            <span class="text-[10px] text-[var(--text-tertiary)] ml-1">
              to {@site.name}
            </span>
          </div>
          <%!-- Method tabs --%>
          <div class="flex items-end gap-0 px-5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0 overflow-x-auto">
            <button
              :for={
                {tab_id, icon, label} <- [
                  {"docker-instructions", "docker", "Docker"},
                  {"systemd-instructions", "remix-terminal-box-fill", "systemd"},
                  {"debian-instructions", "os-debian", "Debian / Ubuntu"},
                  {"terraform-instructions", "terraform", "Terraform"},
                  {"binary-instructions", "remix-tools-fill", "Custom"}
                ]
              }
              phx-click="deploy_tab_selected"
              phx-value-tab={tab_id}
              class={[
                "flex items-center gap-1.5 px-3 py-2.5 mr-2 text-xs font-medium border-b-2 whitespace-nowrap transition-colors",
                if(@deploy_tab == tab_id,
                  do: "border-[var(--brand)] text-[var(--brand)]",
                  else:
                    "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
                )
              ]}
            >
              <.icon name={icon} class="w-3.5 h-3.5 shrink-0" />
              {label}
            </button>
          </div>
          <%!-- Instructions content --%>
          <div class="flex-1 overflow-y-auto">
            <div :if={is_nil(@deploy_env)} class="flex items-center justify-center py-16">
              <p class="text-sm text-[var(--text-tertiary)]">Generating token…</p>
            </div>
            <div :if={@deploy_env}>
              <%!-- Docker --%>
              <div :if={@deploy_tab == "docker-instructions"} class="p-5 space-y-4">
                <p class="text-xs text-[var(--text-secondary)]">
                  Copy-paste this command to your server:
                </p>
                <.code_block
                  id="deploy-code-docker"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_docker_command(@deploy_env) %></.code_block>
                <p class="text-xs text-[var(--text-secondary)]">
                  Using Docker Compose? See our
                  <.website_link path="/kb/automate/docker-compose">
                    sample compose file.
                  </.website_link>
                </p>
                <p class="text-xs text-[var(--text-secondary)]">
                  <strong>Important:</strong>
                  If you need IPv6 support, you must <.link
                    href="https://docs.docker.com/config/daemon/ipv6"
                    class={link_style()}
                    target="_blank"
                  >
                    enable IPv6 in the Docker daemon
                  </.link>.
                </p>
              </div>
              <%!-- systemd --%>
              <div :if={@deploy_tab == "systemd-instructions"} class="p-5 space-y-4">
                <p class="text-xs text-[var(--text-secondary)]">
                  Copy-paste this command to your server:
                </p>
                <.code_block
                  id="deploy-code-systemd"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                ><%= gateway_systemd_command(@deploy_env) %></.code_block>
                <p class="text-xs text-[var(--text-secondary)]">
                  <strong>Important:</strong>
                  Make sure that the <code>iptables</code>
                  and <code>ip6tables</code>
                  commands are available on your system.
                </p>
              </div>
              <%!-- Debian / Ubuntu --%>
              <div :if={@deploy_tab == "debian-instructions"} class="p-5 space-y-4">
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 1: Add the Firezone package repository.
                </p>
                <.code_block
                  id="deploy-code-debian1"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_debian_apt_repository() %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 2: Install the Gateway:
                </p>
                <.code_block
                  id="deploy-code-debian2"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_debian_install() %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 3: Configure a token:
                </p>
                <.code_block
                  id="deploy-code-debian3"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_debian_authenticate() %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 4: Use the below token when prompted:
                </p>
                <.code_block
                  id="deploy-code-debian4"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_token(@deploy_env) %></.code_block>
                <p class="text-xs text-[var(--text-secondary)]">
                  Step 5: You are now ready to manage the Gateway using the <code>firezone</code> CLI.
                </p>
              </div>
              <%!-- Terraform --%>
              <div :if={@deploy_tab == "terraform-instructions"} class="p-5 space-y-4">
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 1: Copy the token shown below to a safe location.
                </p>
                <.code_block
                  id="deploy-code-terraform"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_token(@deploy_env) %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 2: Follow one of our
                  <.website_link path="/kb/automate">Terraform guides</.website_link>
                  to deploy a Gateway for your cloud provider.
                </p>
              </div>
              <%!-- Custom / binary --%>
              <div :if={@deploy_tab == "binary-instructions"} class="p-5 space-y-4">
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 1: <.website_link path="/changelog">Download the latest binary</.website_link>
                  for your architecture.
                </p>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 2: Set required environment variables:
                </p>
                <.code_block
                  id="deploy-code-binary1"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_manual_env(@deploy_env) %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 3: Enable packet forwarding for IPv4 and IPv6:
                </p>
                <.code_block
                  id="deploy-code-binary2"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_manual_forwarding() %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 4: Enable masquerading for ethernet and WiFi interfaces:
                </p>
                <.code_block
                  id="deploy-code-binary3"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= gateway_manual_masquerading() %></.code_block>
                <p class="text-xs font-semibold text-[var(--text-secondary)]">
                  Step 5: Run the binary you downloaded in Step 1:
                </p>
                <.code_block
                  id="deploy-code-binary4"
                  class="w-full text-xs whitespace-pre-line"
                  phx-no-format
                  phx-update="ignore"
                ><%= "sudo ./firezone-gateway-<version>-<architecture>" %></.code_block>
                <p class="text-xs text-[var(--text-secondary)]">
                  <strong>Important:</strong>
                  Make sure to save the <code>FIREZONE_TOKEN</code>
                  shown above to a secure location before continuing. It won't be shown again.
                </p>
              </div>
            </div>
          </div>
          <%!-- Connection status footer --%>
          <div class="shrink-0 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-between gap-4">
            <p class="text-xs text-[var(--text-tertiary)]">
              Gateway not connecting? See our
              <.website_link
                path="/kb/administer/troubleshooting"
                fragment="gateway-not-connecting"
              >
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
        <%!-- Add resource view --%>
        <div :if={@panel_view == :add_resource} class="flex flex-1 min-h-0 flex-col overflow-hidden">
          <%!-- Header --%>
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Add Resource</h2>
              <button
                phx-click="close_add_resource"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="remix-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <%!-- Form --%>
          <.form
            :if={@resource_form}
            for={@resource_form}
            phx-submit="resource_submit"
            phx-change="resource_change"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <%!-- Type --%>
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
                          <.icon name="remix-global-line" class="w-4 h-4 mr-1" /> DNS
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
                          <.icon name="remix-server-line" class="w-4 h-4 mr-1" /> IP
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
                          <.icon name="remix-server-line" class="w-4 h-4 mr-1" /> CIDR
                        </div>
                        <div class="w-full text-[10px]">By CIDR range</div>
                      </div>
                    </label>
                  </li>
                </ul>
              </div>
              <%!-- Address --%>
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
              <%!-- Address Description --%>
              <div>
                <label
                  for={@resource_form[:address_description].id}
                  class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
                >
                  Address Description
                  <span class="text-[var(--text-muted)] font-normal">(optional)</span>
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
              <%!-- Name --%>
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
              <%!-- IP Stack (DNS only) --%>
              <div :if={"#{@resource_form[:type].value}" == "dns"}>
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
              <%!-- Traffic Restrictions --%>
              <div>
                <div class="flex items-center justify-between mb-2">
                  <span class="block text-xs font-medium text-[var(--text-secondary)]">
                    Traffic Restrictions
                    <span class="font-normal text-[var(--text-tertiary)]">(optional)</span>
                  </span>
                  <div class="relative">
                    <button
                      type="button"
                      phx-click="toggle_resource_filters_dropdown"
                      class="inline-flex items-center gap-1 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] border border-[var(--border)] rounded px-2 py-1 bg-[var(--surface)] hover:bg-[var(--surface-raised)] transition-colors"
                    >
                      <.icon name="remix-add-line" class="w-3 h-3" /> Add protocol
                      <.icon name="remix-arrow-down-s-line" class="w-3 h-3" />
                    </button>
                    <div
                      :if={@resource_form_filters_dropdown_open}
                      phx-click-away="close_resource_filters_dropdown"
                      class="absolute right-0 top-full mt-1 z-20 bg-[var(--surface-overlay)] border border-[var(--border)] rounded shadow-md min-w-[120px]"
                    >
                      <button
                        :if={:tcp not in @resource_form_active_protocols}
                        type="button"
                        phx-click="add_resource_filter"
                        phx-value-protocol="tcp"
                        class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                      >
                        TCP
                      </button>
                      <button
                        :if={:udp not in @resource_form_active_protocols}
                        type="button"
                        phx-click="add_resource_filter"
                        phx-value-protocol="udp"
                        class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                      >
                        UDP
                      </button>
                      <button
                        :if={:icmp not in @resource_form_active_protocols}
                        type="button"
                        phx-click="add_resource_filter"
                        phx-value-protocol="icmp"
                        class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                      >
                        ICMP
                      </button>
                      <div
                        :if={
                          :tcp in @resource_form_active_protocols and
                            :udp in @resource_form_active_protocols and
                            :icmp in @resource_form_active_protocols
                        }
                        class="px-3 py-2 text-xs text-[var(--text-tertiary)]"
                      >
                        All protocols added
                      </div>
                    </div>
                  </div>
                </div>
                <div
                  :if={@resource_form_active_protocols == []}
                  class="flex items-center justify-center rounded border border-dashed border-[var(--border)] px-4 py-5 text-xs text-[var(--text-tertiary)]"
                >
                  No restrictions — all traffic is permitted
                </div>
                <div :if={@resource_form_active_protocols != []} class="flex flex-col gap-2">
                  <div
                    :for={protocol <- @resource_form_active_protocols}
                    class="flex items-center gap-2 rounded border border-[var(--border)] bg-[var(--surface)] px-3 py-2"
                  >
                    <input
                      type="hidden"
                      name={"resource[filters][#{protocol}][enabled]"}
                      value="true"
                    />
                    <input
                      type="hidden"
                      name={"resource[filters][#{protocol}][protocol]"}
                      value={"#{protocol}"}
                    />
                    <span class="w-10 shrink-0 text-xs font-medium text-[var(--text-primary)] uppercase">
                      {protocol}
                    </span>
                    <div :if={protocol != :icmp} class="flex-1">
                      <input
                        type="text"
                        name={"resource[filters][#{protocol}][ports]"}
                        value={Map.get(@filter_ports, protocol, "")}
                        placeholder="All ports"
                        class="w-full px-3 py-2 text-sm rounded-md border font-mono bg-[var(--control-bg)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none transition-colors border-[var(--control-border)] focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30"
                      />
                    </div>
                    <span
                      :if={protocol == :icmp}
                      class="flex-1 text-xs text-[var(--text-tertiary)] italic"
                    >
                      echo request/reply
                    </span>
                    <button
                      type="button"
                      phx-click="remove_resource_filter"
                      phx-value-protocol={"#{protocol}"}
                      class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
                      aria-label={"Remove #{protocol} filter"}
                    >
                      <.icon name="remix-close-line" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              </div>
            </div>
            <%!-- Sticky footer --%>
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
          </.form>
        </div>
        <%!-- Edit site view --%>
        <div :if={@panel_view == :edit_site} class="flex flex-1 min-h-0 flex-col overflow-hidden">
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit Site</h2>
              <button
                phx-click="cancel_site_edit_form"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="remix-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <.form
            :if={@site_edit_form}
            for={@site_edit_form}
            phx-submit="submit_site_edit_form"
            phx-change="change_site_edit_form"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <div :if={@site.managed_by == :account}>
                <label
                  for={@site_edit_form[:name].id}
                  class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
                >
                  Name <span class="text-[var(--status-error)]">*</span>
                </label>
                <.input
                  field={@site_edit_form[:name]}
                  type="text"
                  placeholder="Name of this site"
                  phx-debounce="300"
                  required
                />
              </div>
              <div>
                <.input
                  field={@site_edit_form[:health_threshold]}
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
      </div>
    </div>
    """
  end

  # ---- Helpers ----

  defp gateway_online_count(site_id) do
    Presence.Gateways.Site.list(site_id) |> map_size()
  end

  defp compute_site_status(site_id, threshold) do
    online = gateway_online_count(site_id)

    cond do
      online == 0 -> :offline
      online < threshold -> :degraded
      true -> :healthy
    end
  end

  # ---- Gateway deploy command helpers ----

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

  # ---- Events ----

  def handle_event("select_site", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/#{id}")}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}
  end

  def handle_event("switch_panel_tab", %{"tab" => tab}, socket) do
    site = socket.assigns.selected_site

    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/#{site.id}?tab=#{tab}")}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.panel_view == :edit_site do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.new_site_panel do
    {:noreply, assign(socket, new_site_panel: false, new_site_form: nil)}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.panel_view == :deploy do
    {:noreply, assign(socket, panel_view: :gateways)}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.panel_view == :add_resource do
    {:noreply,
     assign(socket,
       panel_view: :gateways,
       panel_tab: :resources,
       resource_form: nil,
       resource_name_changed?: false,
       resource_form_filters_dropdown_open: false,
       resource_form_active_protocols: []
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_site) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_site_panel", _params, socket) do
    changeset = Database.change_site(%Portal.Site{})
    {:noreply, assign(socket, new_site_panel: true, new_site_form: to_form(changeset))}
  end

  def handle_event("close_new_site_panel", _params, socket) do
    {:noreply, assign(socket, new_site_panel: false, new_site_form: nil)}
  end

  def handle_event("new_site_change", %{"site" => attrs}, socket) do
    changeset =
      Database.change_site(%Portal.Site{}, attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, new_site_form: to_form(changeset))}
  end

  def handle_event("new_site_submit", %{"site" => attrs}, socket) do
    account = socket.assigns.account

    with true <- Portal.Billing.can_create_sites?(account),
         changeset = Database.new_site_changeset(account, attrs),
         {:ok, site} <- Database.create_site(changeset, socket.assigns.subject) do
      sites = Database.list_all_sites(socket.assigns.subject)

      {:noreply,
       socket
       |> put_flash(:success, "Site #{site.name} created successfully.")
       |> assign(new_site_panel: false, new_site_form: nil, sites: sites)
       |> push_patch(to: ~p"/#{account}/sites/#{site.id}")}
    else
      false ->
        changeset =
          Database.change_site(%Portal.Site{}, attrs)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> put_flash(
           :error,
           "You have reached the maximum number of sites allowed by your subscription plan."
         )
         |> assign(new_site_form: to_form(changeset))}

      {:error, changeset} ->
        {:noreply, assign(socket, new_site_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("toggle_gateway_expand", %{"id" => id}, socket) do
    expanded =
      if socket.assigns.expanded_gateway_id == id, do: nil, else: id

    {:noreply, assign(socket, :expanded_gateway_id, expanded)}
  end

  def handle_event("show_all_gateways", _params, socket) do
    gateways =
      socket.assigns.selected_site.id
      |> Database.list_gateways_for_site(socket.assigns.subject)
      |> Presence.Gateways.preload_gateways_presence()

    {:noreply, assign(socket, panel_gateways: gateways, panel_show_all_gateways: true)}
  end

  def handle_event("show_online_gateways", _params, socket) do
    gateways =
      socket.assigns.selected_site.id
      |> Database.list_gateways_for_site(socket.assigns.subject)
      |> Presence.Gateways.preload_gateways_presence()
      |> Enum.filter(& &1.online?)

    {:noreply, assign(socket, panel_gateways: gateways, panel_show_all_gateways: false)}
  end

  def handle_event("deploy_gateway", _params, socket) do
    site = socket.assigns.selected_site
    {:ok, token, encoded_token} = Database.create_gateway_token(site, socket.assigns.subject)
    :ok = Presence.Gateways.Site.subscribe(site.id)

    env = [
      {"FIREZONE_ID", Ecto.UUID.generate()},
      {"FIREZONE_TOKEN", encoded_token}
      | if(url = Portal.Config.get_env(:portal, :api_url_override),
          do: [{"FIREZONE_API_URL", url}],
          else: []
        )
    ]

    {:noreply,
     assign(socket,
       panel_view: :deploy,
       deploy_env: env,
       deploy_token: token,
       deploy_connected?: false
     )}
  end

  def handle_event("deploy_tab_selected", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, deploy_tab: tab)}
  end

  def handle_event("close_deploy", _params, socket) do
    {:noreply, assign(socket, panel_view: :gateways)}
  end

  def handle_event("add_resource", _params, socket) do
    changeset = Database.new_resource_changeset(socket.assigns.account)

    {:noreply,
     assign(socket,
       panel_view: :add_resource,
       resource_form: to_form(changeset),
       resource_name_changed?: false,
       resource_form_filters_dropdown_open: false,
       resource_form_active_protocols: []
     )}
  end

  def handle_event("resource_change", %{"resource" => attrs} = payload, socket) do
    name_changed? =
      socket.assigns.resource_name_changed? ||
        payload["_target"] == ["resource", "name"]

    attrs =
      attrs
      |> then(fn a -> if name_changed?, do: a, else: Map.put(a, "name", a["address"]) end)
      |> map_filters_form_attrs(socket.assigns.account)
      |> Map.put("site_id", socket.assigns.selected_site.id)

    changeset =
      Database.new_resource_changeset(socket.assigns.account, attrs)
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket, resource_form: to_form(changeset), resource_name_changed?: name_changed?)}
  end

  def handle_event("resource_submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> then(fn a ->
        if socket.assigns.resource_name_changed?, do: a, else: Map.put(a, "name", a["address"])
      end)
      |> map_filters_form_attrs(socket.assigns.account)
      |> Map.put("site_id", socket.assigns.selected_site.id)

    case Database.create_resource(attrs, socket.assigns.subject) do
      {:ok, resource} ->
        resources =
          Database.list_resources_for_site(
            socket.assigns.selected_site.id,
            socket.assigns.subject
          )

        resources_counts =
          Database.count_resources_by_site(
            Enum.map(socket.assigns.sites, & &1.id),
            socket.assigns.subject
          )

        {:noreply,
         socket
         |> put_flash(:success, "Resource #{resource.name} created successfully.")
         |> assign(
           panel_view: :gateways,
           panel_tab: :resources,
           panel_resources: resources,
           resources_counts: resources_counts,
           resource_form: nil,
           resource_name_changed?: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, resource_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("close_add_resource", _params, socket) do
    {:noreply, assign(socket, panel_view: :gateways, panel_tab: :resources)}
  end

  def handle_event("confirm_delete_site", _params, socket) do
    {:noreply, assign(socket, confirm_delete_site: true)}
  end

  def handle_event("cancel_delete_site", _params, socket) do
    {:noreply, assign(socket, confirm_delete_site: false)}
  end

  def handle_event("delete_site", _params, socket) do
    case Database.delete_site(socket.assigns.selected_site, socket.assigns.subject) do
      {:ok, _site} ->
        sites = Database.list_all_sites(socket.assigns.subject)

        {:noreply,
         socket
         |> put_flash(:success, "Site #{socket.assigns.selected_site.name} deleted successfully.")
         |> assign(sites: sites)
         |> push_patch(to: ~p"/#{socket.assigns.account}/sites")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete site.")
         |> assign(confirm_delete_site: false)}
    end
  end

  def handle_event("open_site_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}/edit"
     )}
  end

  def handle_event("cancel_site_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"
     )}
  end

  def handle_event("change_site_edit_form", %{"site" => attrs}, socket) do
    changeset =
      Database.change_site(socket.assigns.selected_site, attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, site_edit_form: to_form(changeset))}
  end

  def handle_event("submit_site_edit_form", %{"site" => attrs}, socket) do
    changeset = Database.change_site(socket.assigns.selected_site, attrs)

    case Database.update_site(changeset, socket.assigns.subject) do
      {:ok, updated_site} ->
        sites = Database.list_all_sites(socket.assigns.subject)
        site_ids = Enum.map(sites, & &1.id)
        resources_counts = Database.count_resources_by_site(site_ids, socket.assigns.subject)

        {:noreply,
         socket
         |> put_flash(:success, "Site updated successfully.")
         |> assign(
           sites: sites,
           resources_counts: resources_counts
         )
         |> push_patch(to: ~p"/#{socket.assigns.account}/sites/#{updated_site.id}")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, site_edit_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("toggle_resource_filters_dropdown", _params, socket) do
    {:noreply, update(socket, :resource_form_filters_dropdown_open, &(not &1))}
  end

  def handle_event("close_resource_filters_dropdown", _params, socket) do
    {:noreply, assign(socket, resource_form_filters_dropdown_open: false)}
  end

  def handle_event("add_resource_filter", %{"protocol" => protocol}, socket) do
    {:noreply,
     assign(socket,
       resource_form_active_protocols:
         socket.assigns.resource_form_active_protocols ++ [String.to_existing_atom(protocol)],
       resource_form_filters_dropdown_open: false
     )}
  end

  def handle_event("remove_resource_filter", %{"protocol" => protocol}, socket) do
    {:noreply,
     update(
       socket,
       :resource_form_active_protocols,
       &List.delete(&1, String.to_existing_atom(protocol))
     )}
  end

  # ---- Presence updates ----

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:sites:" <> _site_id,
          payload: %{joins: joins}
        },
        socket
      ) do
    if socket.assigns.deploy_connected? or is_nil(socket.assigns.deploy_token) do
      {:noreply, socket}
    else
      connected? =
        Enum.any?(joins, fn {_gateway_id, %{metas: metas}} ->
          Enum.any?(metas, fn meta ->
            Map.get(meta, :token_id) == socket.assigns.deploy_token.id
          end)
        end)

      {:noreply, assign(socket, deploy_connected?: connected?)}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _account_id},
        socket
      ) do
    internet_resource = Database.get_internet_resource(socket.assigns.subject)
    sites = Database.list_all_sites(socket.assigns.subject)
    site_ids = Enum.map(sites, & &1.id)

    internet_site = internet_resource && internet_resource.site

    all_site_ids =
      if internet_site,
        do: [internet_site.id | site_ids],
        else: site_ids

    resources_counts = Database.count_resources_by_site(site_ids, socket.assigns.subject)
    policies_counts = Database.count_policies_by_site(all_site_ids, socket.assigns.subject)
    gateway_counts = Database.count_gateways_by_site(all_site_ids, socket.assigns.subject)

    panel_gateways =
      if socket.assigns.selected_site do
        all =
          socket.assigns.selected_site.id
          |> Database.list_gateways_for_site(socket.assigns.subject)
          |> Presence.Gateways.preload_gateways_presence()

        if socket.assigns.panel_show_all_gateways, do: all, else: Enum.filter(all, & &1.online?)
      else
        socket.assigns.panel_gateways
      end

    socket =
      socket
      |> assign(sites: sites)
      |> assign(resources_counts: resources_counts)
      |> assign(policies_counts: policies_counts)
      |> assign(gateway_counts: gateway_counts)
      |> assign(internet_resource: internet_resource)
      |> assign(internet_site: internet_site)
      |> assign(panel_gateways: panel_gateways)

    {:noreply, socket}
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Safe, Site, Resource, Gateway}

    @spec list_all_sites(Portal.Auth.Subject.t()) :: [Site.t()]
    def list_all_sites(subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.managed_by == :account)
      |> order_by([sites: s], asc: s.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def list_sites(subject, opts \\ []) do
      from(g in Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    @spec get_site(Ecto.UUID.t(), Portal.Auth.Subject.t()) :: Site.t() | nil
    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    @spec list_gateways_for_site(Ecto.UUID.t(), Portal.Auth.Subject.t()) :: [Gateway.t()]
    def list_gateways_for_site(site_id, subject) do
      gateway_ids =
        from(g in Gateway, where: g.site_id == ^site_id, select: g.id)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      gateways =
        from(g in Gateway, as: :gateways)
        |> where([gateways: g], g.site_id == ^site_id)
        |> order_by([gateways: g], asc: g.name)
        |> preload([:ipv4_address, :ipv6_address])
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      account_ids = gateways |> Enum.map(& &1.account_id) |> Enum.uniq()

      sessions_by_gateway_id =
        if gateway_ids != [] do
          from(s in Portal.GatewaySession,
            where: s.account_id in ^account_ids,
            where: s.gateway_id in ^gateway_ids,
            distinct: s.gateway_id,
            order_by: [asc: s.gateway_id, desc: s.inserted_at]
          )
          |> Safe.unscoped(:replica)
          |> Safe.all()
          |> Map.new(&{&1.gateway_id, &1})
        else
          %{}
        end

      Enum.map(gateways, fn gateway ->
        %{gateway | latest_session: Map.get(sessions_by_gateway_id, gateway.id)}
      end)
    end

    @spec list_resources_for_site(Ecto.UUID.t(), Portal.Auth.Subject.t()) :: [Resource.t()]
    def list_resources_for_site(site_id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id == ^site_id)
      |> order_by([resources: r], asc: r.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def count_resources_by_site(site_ids, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count(r.id)})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
    end

    def count_policies_by_site(site_ids, subject) do
      from(p in Portal.Policy, as: :policies)
      |> join(:inner, [policies: p], r in Resource,
        on: r.id == p.resource_id and r.account_id == p.account_id,
        as: :resources
      )
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count()})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
    end

    def count_gateways_by_site(site_ids, subject) do
      from(g in Gateway, as: :gateways)
      |> where([gateways: g], g.site_id in ^site_ids)
      |> group_by([gateways: g], g.site_id)
      |> select([gateways: g], {g.site_id, count(g.id)})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
    end

    @spec new_resource_changeset(Portal.Account.t(), map()) :: Ecto.Changeset.t()
    def new_resource_changeset(account, attrs \\ %{}) do
      %Resource{}
      |> cast(attrs, [:name, :address, :address_description, :type, :ip_stack, :site_id])
      |> validate_required([:name, :address])
      |> put_change(:account_id, account.id)
      |> Resource.changeset()
    end

    @spec create_resource(map(), Portal.Auth.Subject.t()) ::
            {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
    def create_resource(attrs, subject) do
      new_resource_changeset(subject.account, attrs)
      |> validate_required([:site_id])
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def create_gateway_token(site, subject) do
      with {:ok, token} <- Portal.Authentication.create_gateway_token(site, subject) do
        {:ok, %{token | secret_fragment: nil}, Portal.Authentication.encode_fragment!(token)}
      end
    end

    @spec change_site(Site.t(), map()) :: Ecto.Changeset.t()
    def change_site(site, attrs \\ %{})

    def change_site(%Site{managed_by: :system} = site, attrs) do
      site
      |> cast(attrs, [:health_threshold])
      |> Site.changeset()
    end

    def change_site(site, attrs) do
      site
      |> cast(attrs, [:name, :health_threshold])
      |> validate_required([:name])
      |> Site.changeset()
    end

    @spec new_site_changeset(Portal.Account.t(), map()) :: Ecto.Changeset.t()
    def new_site_changeset(account, attrs) do
      %Site{account_id: account.id}
      |> cast(attrs, [:name, :health_threshold])
      |> validate_required([:name])
      |> Site.changeset()
    end

    @spec create_site(Ecto.Changeset.t(), Portal.Auth.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def create_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    @spec update_site(Ecto.Changeset.t(), Portal.Auth.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def update_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end

    @spec delete_site(Site.t(), Portal.Auth.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def delete_site(site, subject) do
      Safe.scoped(site, subject)
      |> Safe.delete()
    end

    def get_internet_resource(subject) do
      resource =
        from(r in Resource, as: :resources)
        |> where([resources: r], r.type == :internet)
        |> preload(site: :gateways)
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case resource do
        nil ->
          nil

        resource ->
          gateways = Presence.Gateways.preload_gateways_presence(resource.site.gateways)
          put_in(resource.site.gateways, gateways)
      end
    end

    def cursor_fields,
      do: [
        {:sites, :asc, :inserted_at},
        {:sites, :asc, :id}
      ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :managed_by,
          type: :string,
          fun: &filter_managed_by/2
        }
      ]
    end

    def filter_managed_by(queryable, value) do
      {queryable, dynamic([sites: sites], sites.managed_by == ^value)}
    end
  end
end
