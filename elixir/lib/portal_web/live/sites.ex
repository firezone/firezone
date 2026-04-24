defmodule PortalWeb.Sites do
  use PortalWeb, :live_view
  import PortalWeb.Sites.Components
  import PortalWeb.Resources.Components, only: [map_filters_form_attrs: 2]
  alias Portal.Presence
  alias Portal.PubSub
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Presence.Gateways.Account.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Sites")
      |> assign(sites_loading?: true)
      |> assign(sites: [])
      |> assign(resources_counts: %{})
      |> assign(policies_counts: %{})
      |> assign(gateway_counts: %{})
      |> assign(internet_resource: nil)
      |> assign(internet_site: nil)
      |> assign(site_state_reset_assigns())

    socket =
      if connected?(socket) do
        load_sites_index_data(socket)
      else
        socket
      end

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :show}} = socket) do
    if selected_site_matches?(socket, id) do
      {:noreply,
       socket
       |> unsubscribe_deploy_site_presence()
       |> merge_state(:site_panel, %{
         tab: String.to_existing_atom(Map.get(params, "tab", "gateways")),
         view: :gateways,
         confirm_delete_site: false,
         expanded_gateway_id: nil
       })
       |> put_state(:site_deploy, base_site_deploy_state())
       |> put_state(:site_resource_form, base_site_resource_form_state())
       |> put_state(:site_edit, base_site_edit_state())}
    else
      case Database.get_site(id, socket.assigns.subject) do
        nil ->
          {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}

        site ->
          {:noreply,
           socket
           |> unsubscribe_deploy_site_presence()
           |> assign(site_panel_assigns(site, params, socket))}
      end
    end
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :edit}} = socket) do
    if selected_site_matches?(socket, id) do
      changeset = Database.change_site(socket.assigns.selected_site)

      {:noreply,
       socket
       |> unsubscribe_deploy_site_presence()
       |> merge_state(:site_panel, %{
         tab: String.to_existing_atom(Map.get(params, "tab", "gateways")),
         view: :edit_site,
         confirm_delete_site: false
       })
       |> put_state(:site_deploy, base_site_deploy_state())
       |> put_state(:site_resource_form, base_site_resource_form_state())
       |> put_state(:site_edit, %{form: to_form(changeset)})}
    else
      case Database.get_site(id, socket.assigns.subject) do
        nil ->
          {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}

        site ->
          changeset = Database.change_site(site)
          site_assigns = site_panel_assigns(site, params, socket)

          {:noreply,
           socket
           |> unsubscribe_deploy_site_presence()
           |> assign(
             Keyword.merge(site_assigns,
               site_panel: Map.put(Keyword.fetch!(site_assigns, :site_panel), :view, :edit_site),
               site_edit: %{form: to_form(changeset)}
             )
           )}
      end
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = Database.change_site(%Portal.Site{})

    {:noreply,
     socket
     |> unsubscribe_deploy_site_presence()
     |> assign(site_state_reset_assigns())
     |> put_state(:new_site, %{open: true, form: to_form(changeset)})}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> unsubscribe_deploy_site_presence() |> assign(site_state_reset_assigns())}
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
        internet_resource = socket.assigns.internet_resource

        if internet_resource && internet_resource.site_id == site.id do
          [internet_resource]
        else
          []
        end
      end

    [
      selected_site: site,
      site_panel:
        Map.merge(base_site_panel_state(), %{
          tab: String.to_existing_atom(Map.get(params, "tab", "gateways")),
          gateways: gateways,
          resources: resources
        }),
      site_deploy: base_site_deploy_state(),
      site_resource_form: base_site_resource_form_state(),
      site_edit: base_site_edit_state(),
      new_site: base_new_site_state()
    ]
  end

  defp site_state_reset_assigns do
    [
      selected_site: nil,
      site_panel: base_site_panel_state(),
      site_deploy: base_site_deploy_state(),
      site_resource_form: base_site_resource_form_state(),
      site_edit: base_site_edit_state(),
      new_site: base_new_site_state()
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
          <.icon name="ri-map-pin-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Sites</:title>
        <:description>
          Logical groupings of gateways - typically mapped to a network location or cloud region.
        </:description>
        <:action>
          <.docs_action path="/deploy/sites" />
          <.button style="primary" icon="ri-add-line" phx-click="open_new_site_panel">
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
            <%= if @sites_loading? do %>
              <tr class="border-b border-[var(--border)] border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-[var(--border-strong)] w-36"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-[var(--border)]"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-16"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-10"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-[var(--border-strong)]"></div>
                    <div class="h-2.5 rounded bg-[var(--border-strong)] w-20"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-[var(--border)] border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-[var(--border-strong)] w-48"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-[var(--border)]"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-12"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-8"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-[var(--border-strong)]"></div>
                    <div class="h-2.5 rounded bg-[var(--border-strong)] w-16"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-[var(--border)] border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-[var(--border-strong)] w-40"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-[var(--border)]"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-20"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-12"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-[var(--border-strong)]"></div>
                    <div class="h-2.5 rounded bg-[var(--border-strong)] w-24"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-[var(--border)] border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-[var(--border-strong)] w-32"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-[var(--border)]"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-14"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-10"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-[var(--border-strong)]"></div>
                    <div class="h-2.5 rounded bg-[var(--border-strong)] w-20"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-[var(--border)] border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-[var(--border-strong)] w-44"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-[var(--border)]"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-16"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-[var(--border-strong)] w-8"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-[var(--border-strong)]"></div>
                    <div class="h-2.5 rounded bg-[var(--border-strong)] w-18"></div>
                  </div>
                </td>
              </tr>
            <% end %>
            <tr
              :if={not @sites_loading? and @internet_site}
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
                  <.icon name="ri-global-line" class="w-5 h-5 text-violet-500" />
                  <div class={[
                    "font-medium transition-colors",
                    if(not is_nil(@selected_site) and @selected_site.id == @internet_site.id,
                      do: "text-[var(--brand)]",
                      else: "text-[var(--text-primary)] group-hover:text-[var(--brand)]"
                    )
                  ]}>
                    Internet
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
                  {online}<span class="text-[var(--text-tertiary)]">/{@internet_site.health_threshold}</span>
                  <span class="ml-1.5 text-[10px] text-[var(--text-tertiary)]">online</span>
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
              :for={site <- if(@sites_loading?, do: [], else: @sites)}
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
                  {online}<span class="text-[var(--text-tertiary)]">/{site.health_threshold}</span>
                  <span class="ml-1.5 text-[10px] text-[var(--text-tertiary)]">online</span>
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
          :if={not @sites_loading? and @sites == [] and is_nil(@internet_site)}
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
        account={@account}
        resources_counts={@resources_counts}
        policies_counts={@policies_counts}
        gateway_counts={@gateway_counts}
        panel={@site_panel}
        deploy_state={@site_deploy}
        resource_form_state={@site_resource_form}
        edit_state={@site_edit}
      />

      <.new_site_panel state={@new_site} />
    </div>
    """
  end

  defp base_site_panel_state do
    %{
      tab: :gateways,
      gateways: [],
      resources: [],
      show_all_gateways: false,
      view: :gateways,
      confirm_delete_site: false,
      expanded_gateway_id: nil
    }
  end

  defp base_site_deploy_state do
    %{
      env: nil,
      tab: "debian-instructions",
      connected?: false,
      token: nil,
      subscribed_site_id: nil
    }
  end

  defp base_site_resource_form_state do
    %{
      form: nil,
      name_changed?: false,
      filters_dropdown_open: false,
      active_protocols: []
    }
  end

  defp base_site_edit_state do
    %{form: nil}
  end

  defp base_new_site_state do
    %{open: false, form: nil}
  end

  defp put_state(socket, key, attrs) do
    assign(socket, key, attrs)
  end

  defp merge_state(socket, key, attrs) do
    update(socket, key, &Map.merge(&1, attrs))
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

  # ---- Events ----

  def handle_event("select_site", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/#{id}")}
  end

  def handle_event("close_panel", _params, socket) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites?#{params}")}
  end

  def handle_event("switch_panel_tab", %{"tab" => tab}, socket) do
    site = socket.assigns.selected_site
    params = Map.put(socket.assigns.query_params, "tab", tab)

    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/#{site.id}?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :edit_site do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.new_site.open do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :deploy do
    {:noreply, merge_state(socket, :site_panel, %{view: :gateways})}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :add_resource do
    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :gateways, tab: :resources})
     |> put_state(:site_resource_form, base_site_resource_form_state())}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_site) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_site_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/new")}
  end

  def handle_event("close_new_site_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}
  end

  def handle_event("new_site_change", %{"site" => attrs}, socket) do
    changeset =
      Database.change_site(%Portal.Site{}, attrs)
      |> Map.put(:action, :validate)

    {:noreply, merge_state(socket, :new_site, %{form: to_form(changeset)})}
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
       |> put_state(:new_site, base_new_site_state())
       |> assign(sites: sites)
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
         |> merge_state(:new_site, %{form: to_form(changeset)})}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :new_site, %{form: to_form(Map.put(changeset, :action, :validate))})}
    end
  end

  def handle_event("toggle_gateway_expand", %{"id" => id}, socket) do
    expanded =
      if socket.assigns.site_panel.expanded_gateway_id == id, do: nil, else: id

    {:noreply, merge_state(socket, :site_panel, %{expanded_gateway_id: expanded})}
  end

  def handle_event("show_all_gateways", _params, socket) do
    gateways =
      socket.assigns.selected_site.id
      |> Database.list_gateways_for_site(socket.assigns.subject)
      |> Presence.Gateways.preload_gateways_presence()

    {:noreply, merge_state(socket, :site_panel, %{gateways: gateways, show_all_gateways: true})}
  end

  def handle_event("show_online_gateways", _params, socket) do
    gateways =
      socket.assigns.selected_site.id
      |> Database.list_gateways_for_site(socket.assigns.subject)
      |> Presence.Gateways.preload_gateways_presence()
      |> Enum.filter(& &1.online?)

    {:noreply, merge_state(socket, :site_panel, %{gateways: gateways, show_all_gateways: false})}
  end

  def handle_event("deploy_gateway", _params, socket) do
    site = socket.assigns.selected_site
    {:ok, token, encoded_token} = Database.create_gateway_token(site, socket.assigns.subject)

    socket =
      socket
      |> unsubscribe_deploy_site_presence()
      |> subscribe_deploy_site_presence(site.id)

    env = [
      {"FIREZONE_ID", Ecto.UUID.generate()},
      {"FIREZONE_TOKEN", encoded_token}
      | if(url = Portal.Config.get_env(:portal, :api_url_override),
          do: [{"FIREZONE_API_URL", url}],
          else: []
        )
    ]

    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :deploy})
     |> put_state(:site_deploy, %{
       env: env,
       tab: "debian-instructions",
       token: token,
       connected?: false,
       subscribed_site_id: site.id
     })}
  end

  def handle_event("deploy_tab_selected", %{"tab" => tab}, socket) do
    {:noreply, merge_state(socket, :site_deploy, %{tab: tab})}
  end

  def handle_event("close_deploy", _params, socket) do
    {:noreply,
     socket
     |> unsubscribe_deploy_site_presence()
     |> merge_state(:site_panel, %{view: :gateways})
     |> put_state(:site_deploy, base_site_deploy_state())}
  end

  def handle_event("add_resource", _params, socket) do
    changeset = Database.new_resource_changeset(socket.assigns.account)

    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :add_resource})
     |> put_state(:site_resource_form, %{
       form: to_form(changeset),
       name_changed?: false,
       filters_dropdown_open: false,
       active_protocols: []
     })}
  end

  def handle_event("resource_change", %{"resource" => attrs} = payload, socket) do
    name_changed? =
      socket.assigns.site_resource_form.name_changed? ||
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
     merge_state(socket, :site_resource_form, %{
       form: to_form(changeset),
       name_changed?: name_changed?
     })}
  end

  def handle_event("resource_submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> then(fn a ->
        if socket.assigns.site_resource_form.name_changed?,
          do: a,
          else: Map.put(a, "name", a["address"])
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
         |> merge_state(:site_panel, %{view: :gateways, tab: :resources, resources: resources})
         |> put_state(:site_resource_form, base_site_resource_form_state())
         |> assign(resources_counts: resources_counts)}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :site_resource_form, %{
           form: to_form(Map.put(changeset, :action, :validate))
         })}
    end
  end

  def handle_event("close_add_resource", _params, socket) do
    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :gateways, tab: :resources})
     |> put_state(:site_resource_form, base_site_resource_form_state())}
  end

  def handle_event("confirm_delete_site", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_delete_site: true})}
  end

  def handle_event("cancel_delete_site", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_delete_site: false})}
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
         |> merge_state(:site_panel, %{confirm_delete_site: false})}
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

    {:noreply, merge_state(socket, :site_edit, %{form: to_form(changeset)})}
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
         merge_state(socket, :site_edit, %{form: to_form(Map.put(changeset, :action, :validate))})}
    end
  end

  def handle_event("toggle_resource_filters_dropdown", _params, socket) do
    {:noreply,
     update(
       socket,
       :site_resource_form,
       &Map.update!(&1, :filters_dropdown_open, fn open -> not open end)
     )}
  end

  def handle_event("close_resource_filters_dropdown", _params, socket) do
    {:noreply, merge_state(socket, :site_resource_form, %{filters_dropdown_open: false})}
  end

  def handle_event("add_resource_filter", %{"protocol" => protocol}, socket) do
    {:noreply,
     merge_state(socket, :site_resource_form, %{
       active_protocols:
         socket.assigns.site_resource_form.active_protocols ++ [String.to_existing_atom(protocol)],
       filters_dropdown_open: false
     })}
  end

  def handle_event("remove_resource_filter", %{"protocol" => protocol}, socket) do
    {:noreply,
     update(
       socket,
       :site_resource_form,
       &Map.update!(&1, :active_protocols, fn protocols ->
         List.delete(protocols, String.to_existing_atom(protocol))
       end)
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
    case site_deploy_connection_status(socket.assigns.site_deploy, joins) do
      :noop ->
        {:noreply, socket}

      connected? ->
        {:noreply, merge_state(socket, :site_deploy, %{connected?: connected?})}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _account_id},
        socket
      ) do
    socket = load_sites_index_data(socket)

    panel_gateways =
      if socket.assigns.selected_site do
        all =
          socket.assigns.selected_site.id
          |> Database.list_gateways_for_site(socket.assigns.subject)
          |> Presence.Gateways.preload_gateways_presence()

        if socket.assigns.site_panel.show_all_gateways,
          do: all,
          else: Enum.filter(all, & &1.online?)
      else
        socket.assigns.site_panel.gateways
      end

    socket =
      merge_state(socket, :site_panel, %{gateways: panel_gateways})

    {:noreply, socket}
  end

  defp selected_site_matches?(socket, id) do
    match?(%{id: ^id}, socket.assigns.selected_site)
  end

  defp subscribe_deploy_site_presence(socket, site_id) do
    if connected?(socket) and socket.assigns.site_deploy.subscribed_site_id != site_id do
      :ok = Presence.Gateways.Site.subscribe(site_id)
      merge_state(socket, :site_deploy, %{subscribed_site_id: site_id})
    else
      socket
    end
  end

  defp unsubscribe_deploy_site_presence(socket) do
    if connected?(socket) do
      site_id = socket.assigns.site_deploy.subscribed_site_id
        :ok = PubSub.unsubscribe("presences:sites:#{site_id}")
        merge_state(socket, :site_deploy, %{subscribed_site_id: nil})
    else
        socket
    end
  end

  defp site_deploy_connection_status(%{connected?: true}, _joins), do: :noop

  defp site_deploy_connection_status(%{token: nil}, _joins), do: :noop

  defp site_deploy_connection_status(%{token: %{id: token_id}}, joins) do
    deploy_token_connected?(joins, token_id)
  end

  defp deploy_token_connected?(joins, token_id) do
    Enum.any?(joins, fn {_gateway_id, %{metas: metas}} ->
      Enum.any?(metas, fn meta -> Map.get(meta, :token_id) == token_id end)
    end)
  end

  defp load_sites_index_data(socket) do
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

    socket
    |> assign(sites_loading?: false)
    |> assign(sites: sites)
    |> assign(resources_counts: resources_counts)
    |> assign(policies_counts: policies_counts)
    |> assign(gateway_counts: gateway_counts)
    |> assign(internet_resource: internet_resource)
    |> assign(internet_site: internet_site)
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Safe, Site, Resource, Device}

    @spec list_all_sites(Portal.Authentication.Subject.t()) :: [Site.t()]
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

    @spec get_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: Site.t() | nil
    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    @spec list_gateways_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            Device.t()
          ]
    def list_gateways_for_site(site_id, subject) do
      gateway_ids =
        from(d in Device, where: d.site_id == ^site_id, where: d.type == :gateway, select: d.id)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      gateways =
        from(d in Device, as: :devices)
        |> where([devices: d], d.type == :gateway)
        |> where([devices: d], d.site_id == ^site_id)
        |> order_by([devices: d], asc: d.name)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      sessions_by_device_id =
        if gateway_ids != [] do
          from(s in Portal.GatewaySession,
            where: s.device_id in ^gateway_ids,
            distinct: s.device_id,
            order_by: [asc: s.device_id, desc: s.inserted_at]
          )
          |> Safe.scoped(subject, :replica)
          |> Safe.all()
          |> Map.new(&{&1.device_id, &1})
        else
          %{}
        end

      Enum.map(gateways, fn gateway ->
        %{gateway | latest_session: Map.get(sessions_by_device_id, gateway.id)}
      end)
    end

    @spec list_resources_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            Resource.t()
          ]
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
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :gateway)
      |> where([devices: d], d.site_id in ^site_ids)
      |> group_by([devices: d], d.site_id)
      |> select([devices: d], {d.site_id, count(d.id)})
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

    @spec create_resource(map(), Portal.Authentication.Subject.t()) ::
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

    # credo:disable-for-next-line Credo.Check.Warning.SpecWithStruct
    @spec change_site(%Site{}, term()) :: Ecto.Changeset.t()
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

    @spec create_site(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def create_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    @spec update_site(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def update_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end

    @spec delete_site(Site.t(), Portal.Authentication.Subject.t()) ::
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
