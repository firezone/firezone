# credo:disable-for-this-file Credo.Check.Warning.CrossModuleDatabaseCall
defmodule PortalWeb.Resources do
  use PortalWeb, :live_view

  import PortalWeb.Policies.Components,
    only: [
      map_condition_params: 2,
      maybe_drop_unsupported_conditions: 2,
      grant_condition_card: 1,
      available_conditions: 1,
      condition_type_label: 1
    ]

  import PortalWeb.Resources.Components,
    only: [
      map_filters_form_attrs: 2,
      resource_type_picker: 1,
      resource_core_fields: 1,
      resource_device_pool_section: 1,
      resource_dns_ip_stack_section: 1,
      resource_traffic_restrictions_section: 1,
      resource_site_selector: 1
    ]

  alias Portal.Changes.Change
  alias Portal.Presence
  alias Portal.PubSub
  alias Portal.Resource
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id)
      :ok = Presence.Gateways.Account.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(stale: false)
      |> assign(page_title: "Resources")
      |> assign(selected_resource: nil, selected_groups: [], internet_resource: nil)
      |> assign(panel_reset_assigns())
      |> assign(resource_form_assigns(nil, []))
      |> assign(panel_runtime_assigns(socket))
      |> assign_live_table("resources",
        query_module: Database,
        sortable_fields: [
          {:resources, :name},
          {:resources, :address}
        ],
        callback: &handle_resources_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    resource = Database.get_resource!(id, socket.assigns.subject)
    groups = Database.list_groups_for_resource(resource, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    filter_site = filter_site_from_params(params, socket.assigns.subject)

    {:noreply,
     assign(
       socket,
       [filter_site: filter_site, selected_resource: resource, selected_groups: groups] ++
         panel_reset_assigns() ++ resource_form_assigns(nil, [])
     )}
  end

  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    sites = Database.all_sites(socket.assigns.subject)
    changeset = Database.new_resource(socket.assigns.account)
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(
       socket,
       [filter_site: nil, selected_resource: nil, selected_groups: []] ++
         panel_reset_assigns(panel_view: :new_form) ++
         resource_form_assigns(to_form(changeset), sites)
     )}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    resource = Database.get_resource!(id, socket.assigns.subject)

    if resource.type == :internet do
      {:noreply, push_patch(socket, to: resource_show_path(socket, id))}
    else
      sites = Database.all_sites(socket.assigns.subject)
      changeset = Database.change_resource(resource)
      selected_clients = Database.list_pool_members(resource, socket.assigns.subject)
      socket = handle_live_tables_params(socket, params, uri)

      {:noreply,
       assign(
         socket,
         [filter_site: nil, selected_resource: resource, selected_groups: []] ++
           panel_reset_assigns(panel_view: :edit_form) ++
           resource_form_assigns(
             to_form(changeset),
             sites,
             resource_form_active_protocols: Enum.map(resource.filters, & &1.protocol),
             resource_form_selected_clients: selected_clients
           )
       )}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    filter_site = filter_site_from_params(params, socket.assigns.subject)

    {:noreply,
     assign(
       socket,
       [filter_site: filter_site, selected_resource: nil, selected_groups: []] ++
         panel_reset_assigns() ++ resource_form_assigns(nil, [])
     )}
  end

  defp panel_runtime_assigns(socket) do
    [
      timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
      client_to_client_enabled?: Database.client_to_client_enabled?(socket.assigns.account)
    ]
  end

  defp panel_reset_assigns(overrides \\ []) do
    Keyword.merge(
      [
        panel_view: :list,
        available_groups: [],
        providers: [],
        grant_group_id: nil,
        grant_form: nil,
        grant_search: "",
        location_search: "",
        location_operator: "is_in",
        location_values: [],
        ip_range_operator: "is_in_cidr",
        ip_range_values: [],
        ip_range_input: "",
        auth_provider_operator: "is_in",
        auth_provider_values: [],
        active_conditions: [],
        conditions_dropdown_open: false,
        confirm_remove_group_id: nil,
        group_actions_open_id: nil,
        confirm_delete_resource: false
      ],
      overrides
    )
  end

  defp resource_form_assigns(resource_form, sites, overrides \\ []) do
    Keyword.merge(
      [
        resource_form: resource_form,
        resource_form_sites: sites,
        resource_form_name_changed?: false,
        resource_form_address_description_changed?: false,
        resource_form_active_protocols: [],
        resource_form_filters_dropdown_open: false,
        resource_form_selected_clients: [],
        resource_form_client_search: "",
        resource_form_client_search_results: nil
      ],
      overrides
    )
  end

  defp filter_site_from_params(params, subject) do
    with %{"resources_filter" => %{"site_id" => site_id}} <- params do
      Database.get_site(site_id, subject)
    else
      _ -> nil
    end
  end

  defp resources_index_path(socket), do: ~p"/#{socket.assigns.account}/resources"
  defp new_resource_path(socket), do: ~p"/#{socket.assigns.account}/resources/new"

  defp resource_show_path(socket, resource_id),
    do: ~p"/#{socket.assigns.account}/resources/#{resource_id}"

  defp edit_resource_path(socket, resource_id),
    do: ~p"/#{socket.assigns.account}/resources/#{resource_id}/edit"

  defp cancel_resource_form_path(socket) do
    case socket.assigns.live_action do
      :edit -> resource_show_path(socket, socket.assigns.selected_resource.id)
      _ -> resources_index_path(socket)
    end
  end

  def handle_resources_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:site])

    with {:ok, resources, metadata} <-
           Database.list_resources(socket.assigns.subject, list_opts) do
      internet_resource =
        if Portal.Account.internet_resource_enabled?(socket.assigns.account) do
          Database.get_internet_resource(socket.assigns.subject)
        end

      all_resources =
        if internet_resource, do: [internet_resource | resources], else: resources

      resource_policy_counts =
        Database.count_policies_for_resources(all_resources, socket.assigns.subject)

      {:ok,
       assign(socket,
         resources: resources,
         internet_resource: internet_resource,
         resource_policy_counts: resource_policy_counts,
         resources_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="remix-server-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Resources</:title>
        <:description>
          Network endpoints accessible through Firezone.
        </:description>
        <:action>
          <.docs_action path="/deploy/resources" />
          <.button style="primary" icon="remix-add-line" phx-click="open_new_form">
            New Resource
          </.button>
        </:action>
        <:filters>
          <% online_count = Enum.count(@resources, &resource_online?/1) %>
          <% offline_count = length(@resources) - online_count %>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {@resources_metadata.count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="relative flex items-center justify-center w-1.5 h-1.5">
              <span class="absolute inline-flex rounded-full opacity-60 animate-ping w-1.5 h-1.5 bg-[var(--status-active)]">
              </span>
              <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-active)]">
              </span>
            </span>
            Online {online_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-neutral)]">
            </span>
            Offline {offline_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          stale={@stale}
          id="resources"
          rows={@resources}
          row_id={&"resource-#{&1.id}"}
          row_click={fn r -> ~p"/#{@account}/resources/#{r.id}?#{@query_params}" end}
          row_selected={fn r -> not is_nil(@selected_resource) and r.id == @selected_resource.id end}
          filters={@filters_by_table_id["resources"]}
          filter={@filter_form_by_table_id["resources"]}
          ordered_by={@order_by_table_id["resources"]}
          metadata={@resources_metadata}
          class="flex-1 min-h-0"
        >
          <:prepend_rows :if={not is_nil(@internet_resource)}>
            <tr
              class={[
                "border-b border-[var(--border)] cursor-pointer transition-colors group",
                "bg-violet-50/60 dark:bg-violet-950/20",
                if(
                  not is_nil(@selected_resource) and
                    @selected_resource.id == @internet_resource.id,
                  do: "border-l-4 border-l-[var(--brand)]",
                  else: "hover:bg-violet-100/60 dark:hover:bg-violet-900/20"
                )
              ]}
              phx-click="table_row_click"
              phx-value-path={~p"/#{@account}/resources/#{@internet_resource.id}"}
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
                  <div class="font-semibold transition-colors text-[var(--text-primary)] group-hover:text-[var(--brand)]">
                    Internet Resource
                  </div>
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-200/70 text-violet-700 dark:bg-violet-900/40 dark:text-violet-300">
                    system
                  </span>
                </div>
                <div class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  All network traffic not destined for a specific resource
                </div>
              </td>
              <td class="px-4 py-3">
                <span class={type_badge_class(:internet)}>
                  {resource_type_label(:internet)}
                </span>
              </td>
              <td class="px-4 py-3 hidden lg:table-cell">
                <span class="font-mono text-sm text-[var(--text-primary)]">0.0.0.0/0, ::/0</span>
              </td>
              <td class="px-4 py-3">
                <% count = Map.get(@resource_policy_counts, @internet_resource.id, 0) %>
                <.link
                  :if={count > 0}
                  navigate={
                    ~p"/#{@account}/policies?policies_filter[resource_id]=#{@internet_resource.id}"
                  }
                >
                  <span class="inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums bg-[var(--brand-muted)] text-[var(--brand)]">
                    {count}
                  </span>
                </.link>
                <span
                  :if={count == 0}
                  class="inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)]"
                >
                  0
                </span>
              </td>
              <td class="px-4 py-3 text-[var(--text-secondary)] text-xs">Internet</td>
              <td class="px-4 py-3">
                <.status_badge status={
                  if resource_online?(@internet_resource), do: :online, else: :offline
                } />
              </td>
            </tr>
          </:prepend_rows>
          <:notice :if={@filter_site} type="info">
            Viewing Resources for Site <strong>{@filter_site.name}</strong>.
            <.link navigate={~p"/#{@account}/resources"} class={link_style()}>
              View all resources
            </.link>
          </:notice>
          <:col :let={resource} field={{:resources, :name}} label="Name">
            <div class="font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
              {resource.name}
            </div>
            <div class={[
              "text-xs mt-0.5 truncate max-w-xs",
              if(resource.address_description,
                do: "text-[var(--text-tertiary)]",
                else: "text-[var(--text-muted)] italic"
              )
            ]}>
              {resource.address_description || "No Address Description"}
            </div>
          </:col>
          <:col :let={resource} label="Type" class="w-32">
            <span class={type_badge_class(resource.type)}>
              {resource_type_label(resource.type)}
            </span>
          </:col>
          <:col
            :let={resource}
            field={{:resources, :address}}
            label="Address"
            class="hidden lg:table-cell"
          >
            <span
              :if={resource.type not in [:internet, :static_device_pool]}
              class="font-mono text-sm text-[var(--text-primary)]"
            >
              {resource.address}
            </span>
            <span
              :if={resource.type == :internet}
              class="font-mono text-sm text-[var(--text-primary)]"
            >
              0.0.0.0/0, ::/0
            </span>
            <span
              :if={resource.type == :static_device_pool}
              class="font-mono text-sm italic text-[var(--text-tertiary)]"
            >
              Multiple Addresses
            </span>
          </:col>
          <:col :let={resource} label="Policies" class="w-20">
            <% count = Map.get(@resource_policy_counts, resource.id, 0) %>
            <.link
              :if={count > 0}
              navigate={~p"/#{@account}/policies?policies_filter[resource_id]=#{resource.id}"}
            >
              <span class="inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums bg-[var(--brand-muted)] text-[var(--brand)]">
                {count}
              </span>
            </.link>
            <span
              :if={count == 0}
              class="inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)]"
            >
              0
            </span>
          </:col>
          <:col :let={resource} label="Site">
            <.link
              :if={resource.site}
              navigate={~p"/#{@account}/sites/#{resource.site}"}
              class="text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
            >
              {resource.site.name}
            </.link>
            <span :if={is_nil(resource.site)} class="text-[var(--text-muted)] italic">
              No Site Needed
            </span>
          </:col>
          <:col :let={resource} label="Status" class="w-32">
            <.status_badge status={if resource_online?(resource), do: :online, else: :offline} />
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <svg
                  class="w-4 h-4 text-[var(--text-tertiary)]"
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                >
                  <rect x="2" y="2" width="5" height="5" rx="0.75" />
                  <rect x="9" y="2" width="5" height="5" rx="0.75" />
                  <rect x="2" y="9" width="5" height="5" rx="0.75" />
                  <rect x="9" y="9" width="5" height="5" rx="0.75" />
                </svg>
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No resources yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  No resources have been added yet.
                </p>
              </div>
              <.link
                patch={~p"/#{@account}/resources/new"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-add-line" class="w-3 h-3" /> Add a Resource
              </.link>
            </div>
          </:empty>
        </.live_table>
      </div>
      <.panel_shell open={not is_nil(@selected_resource) or @panel_view in [:new_form, :edit_form]}>
        <%= if @panel_view in [:new_form, :edit_form] do %>
          <.resource_form_panel
            resource={@selected_resource}
            panel_view={@panel_view}
            form_state={resource_form_panel_state(assigns)}
          />
        <% end %>

        <%= if @selected_resource && @panel_view not in [:new_form, :edit_form] do %>
          <.resource_details_panel
            account={@account}
            resource={@selected_resource}
            groups={@selected_groups}
            panel_view={@panel_view}
            grant_state={resource_grant_panel_state(assigns)}
            ui_state={resource_panel_ui_state(assigns)}
          />
        <% end %>
      </.panel_shell>
    </div>
    """
  end

  def handle_event(event, params, socket)
      when event in [
             "paginate",
             "order_by",
             "filter",
             "reload",
             "table_row_click",
             "change_limit"
           ],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: resources_index_path(socket))}
  end

  def handle_event("open_new_form", _params, socket) do
    {:noreply, push_patch(socket, to: new_resource_path(socket))}
  end

  def handle_event(
        "open_edit_form",
        _params,
        %{assigns: %{selected_resource: %{type: :internet}}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("open_edit_form", _params, socket) do
    resource = socket.assigns.selected_resource

    {:noreply, push_patch(socket, to: edit_resource_path(socket, resource.id))}
  end

  def handle_event("cancel_resource_form", _params, socket) do
    {:noreply, push_patch(socket, to: cancel_resource_form_path(socket))}
  end

  def handle_event("change_resource_form", %{"resource" => attrs} = payload, socket) do
    name_changed? =
      socket.assigns.resource_form_name_changed? ||
        payload["_target"] == ["resource", "name"]

    address_description_changed? =
      socket.assigns.resource_form_address_description_changed? ||
        payload["_target"] == ["resource", "address_description"]

    attrs = map_filters_form_attrs(attrs, socket.assigns.account)

    changeset =
      if socket.assigns.panel_view == :new_form do
        attrs = maybe_put_default_name(attrs, name_changed?)
        Database.new_resource(socket.assigns.account, attrs)
      else
        Database.change_resource(socket.assigns.selected_resource, attrs)
      end
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket,
       resource_form: to_form(changeset),
       resource_form_name_changed?: name_changed?,
       resource_form_address_description_changed?: address_description_changed?
     )}
  end

  def handle_event("submit_resource_form", %{"resource" => attrs}, socket) do
    attrs = map_filters_form_attrs(attrs, socket.assigns.account)

    if socket.assigns.panel_view == :new_form do
      attrs = maybe_put_default_name(attrs, socket.assigns.resource_form_name_changed?)

      case Database.create_resource(
             attrs,
             socket.assigns.resource_form_selected_clients,
             socket.assigns.subject
           ) do
        {:ok, resource} ->
          socket = put_flash(socket, :success, "Resource #{resource.name} created successfully")

          {:noreply,
           socket
           |> reload_live_table!("resources")
           |> push_patch(to: ~p"/#{socket.assigns.account}/resources/#{resource.id}")}

        {:error, changeset} ->
          changeset = Map.put(changeset, :action, :validate)
          {:noreply, assign(socket, resource_form: to_form(changeset))}
      end
    else
      resource = socket.assigns.selected_resource

      case Database.update_resource(
             resource,
             attrs,
             socket.assigns.resource_form_selected_clients,
             socket.assigns.subject
           ) do
        {:ok, updated_resource} ->
          socket =
            put_flash(socket, :success, "Resource #{updated_resource.name} updated successfully")

          {:noreply,
           socket
           |> reload_live_table!("resources")
           |> push_patch(to: ~p"/#{socket.assigns.account}/resources/#{updated_resource.id}")}

        {:error, changeset} ->
          changeset = Map.put(changeset, :action, :validate)
          {:noreply, assign(socket, resource_form: to_form(changeset))}
      end
    end
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.panel_view in [:new_form, :edit_form] do
    {:noreply, push_patch(socket, to: cancel_resource_form_path(socket))}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_resource) do
    {:noreply, push_patch(socket, to: resources_index_path(socket))}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_resource_filter", %{"protocol" => protocol}, socket) do
    protocol = String.to_existing_atom(protocol)
    active = socket.assigns.resource_form_active_protocols

    {:noreply,
     assign(socket,
       resource_form_active_protocols:
         if(protocol in active, do: active, else: active ++ [protocol]),
       resource_form_filters_dropdown_open: false
     )}
  end

  def handle_event("remove_resource_filter", %{"protocol" => protocol}, socket) do
    protocol = String.to_existing_atom(protocol)

    {:noreply,
     assign(socket,
       resource_form_active_protocols:
         List.delete(socket.assigns.resource_form_active_protocols, protocol)
     )}
  end

  def handle_event("toggle_resource_filters_dropdown", _params, socket) do
    {:noreply,
     assign(socket,
       resource_form_filters_dropdown_open: !socket.assigns.resource_form_filters_dropdown_open
     )}
  end

  def handle_event("close_resource_filters_dropdown", _params, socket) do
    {:noreply, assign(socket, resource_form_filters_dropdown_open: false)}
  end

  def handle_event("focus_client_search", _params, socket) do
    results =
      Database.search_clients(
        socket.assigns.resource_form_client_search,
        socket.assigns.subject,
        socket.assigns.resource_form_selected_clients
      )

    {:noreply, assign(socket, resource_form_client_search_results: results)}
  end

  def handle_event("blur_client_search", _params, socket) do
    {:noreply, assign(socket, resource_form_client_search_results: nil)}
  end

  def handle_event("search_client", %{"client_search" => search}, socket) do
    results =
      Database.search_clients(
        search,
        socket.assigns.subject,
        socket.assigns.resource_form_selected_clients
      )

    {:noreply,
     assign(socket,
       resource_form_client_search: search,
       resource_form_client_search_results: results
     )}
  end

  def handle_event("add_client", %{"client_id" => client_id}, socket) do
    case Database.get_client(client_id, socket.assigns.subject) do
      nil ->
        {:noreply, socket}

      client ->
        selected =
          Enum.uniq_by([client | socket.assigns.resource_form_selected_clients], & &1.id)

        {:noreply,
         assign(socket,
           resource_form_selected_clients: selected,
           resource_form_client_search: "",
           resource_form_client_search_results: nil
         )}
    end
  end

  def handle_event("remove_client", %{"client_id" => client_id}, socket) do
    selected =
      Enum.reject(socket.assigns.resource_form_selected_clients, &(&1.id == client_id))

    results =
      Database.search_clients(
        socket.assigns.resource_form_client_search,
        socket.assigns.subject,
        selected
      )

    {:noreply,
     assign(socket,
       resource_form_selected_clients: selected,
       resource_form_client_search_results: results
     )}
  end

  def handle_event("open_grant_form", _params, socket) do
    resource = socket.assigns.selected_resource
    existing_ids = Enum.map(socket.assigns.selected_groups, & &1.id)
    available = Database.list_available_groups(resource, existing_ids, socket.assigns.subject)
    providers = Database.list_providers(socket.assigns.subject)

    {:noreply,
     socket
     |> assign(
       panel_reset_assigns(
         panel_view: :grant_form,
         available_groups: available,
         providers: providers,
         grant_form: to_grant_form()
       )
     )}
  end

  def handle_event("close_grant_form", _params, socket) do
    {:noreply, assign(socket, panel_reset_assigns())}
  end

  def handle_event("search_grant_groups", %{"value" => search}, socket) do
    {:noreply, assign(socket, grant_search: search)}
  end

  def handle_event("update_location_search", %{"_location_search" => search}, socket) do
    {:noreply, assign(socket, location_search: search)}
  end

  def handle_event("change_location_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, location_operator: op)}
  end

  def handle_event("change_ip_range_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, ip_range_operator: op)}
  end

  def handle_event("update_ip_range_input", %{"_ip_range_input" => value}, socket) do
    {:noreply, assign(socket, ip_range_input: value)}
  end

  def handle_event("add_ip_range_value", _params, socket) do
    value = String.trim(socket.assigns.ip_range_input)

    if value != "" and value not in socket.assigns.ip_range_values do
      {:noreply,
       assign(socket,
         ip_range_values: socket.assigns.ip_range_values ++ [value],
         ip_range_input: ""
       )}
    else
      {:noreply, assign(socket, ip_range_input: "")}
    end
  end

  def handle_event("remove_ip_range_value", %{"value" => value}, socket) do
    {:noreply,
     assign(socket, ip_range_values: List.delete(socket.assigns.ip_range_values, value))}
  end

  def handle_event("change_auth_provider_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, auth_provider_operator: op)}
  end

  def handle_event("toggle_auth_provider_value", %{"id" => id}, socket) do
    values = socket.assigns.auth_provider_values

    updated =
      if id in values do
        List.delete(values, id)
      else
        values ++ [id]
      end

    {:noreply, assign(socket, auth_provider_values: updated)}
  end

  def handle_event("toggle_location_value", %{"code" => code}, socket) do
    values = socket.assigns.location_values

    updated =
      if code in values do
        List.delete(values, code)
      else
        values ++ [code]
      end

    {:noreply, assign(socket, location_values: updated)}
  end

  def handle_event("select_grant_group", %{"group_id" => group_id}, socket) do
    {:noreply, assign(socket, grant_group_id: group_id)}
  end

  def handle_event("submit_grant", %{"policy" => params}, socket) do
    resource = socket.assigns.selected_resource

    attrs =
      params
      |> Map.put("resource_id", resource.id)
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    case Database.insert_policy(attrs, socket.assigns.subject) do
      {:ok, _policy} ->
        groups = Database.list_groups_for_resource(resource, socket.assigns.subject)

        {:noreply,
         socket
         |> assign([selected_groups: groups] ++ panel_reset_assigns())
         |> reload_live_table!("resources")}

      {:error, changeset} ->
        {:noreply, assign(socket, grant_form: to_form(changeset, as: :policy))}
    end
  end

  def handle_event("toggle_group_actions", %{"group_id" => id}, socket) do
    current = socket.assigns.group_actions_open_id
    {:noreply, assign(socket, group_actions_open_id: if(current == id, do: nil, else: id))}
  end

  def handle_event("close_group_actions", _params, socket) do
    {:noreply, assign(socket, group_actions_open_id: nil)}
  end

  def handle_event("disable_policy", %{"group_id" => group_id}, socket) do
    case Database.disable_policy_for_group(
           socket.assigns.selected_resource,
           group_id,
           socket.assigns.subject
         ) do
      {:ok, _} ->
        groups =
          Database.list_groups_for_resource(
            socket.assigns.selected_resource,
            socket.assigns.subject
          )

        {:noreply, assign(socket, selected_groups: groups, group_actions_open_id: nil)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("enable_policy", %{"group_id" => group_id}, socket) do
    case Database.enable_policy_for_group(
           socket.assigns.selected_resource,
           group_id,
           socket.assigns.subject
         ) do
      {:ok, _} ->
        groups =
          Database.list_groups_for_resource(
            socket.assigns.selected_resource,
            socket.assigns.subject
          )

        {:noreply, assign(socket, selected_groups: groups, group_actions_open_id: nil)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "confirm_delete_resource",
        _params,
        %{assigns: %{selected_resource: %{type: :internet}}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("confirm_delete_resource", _params, socket) do
    {:noreply, assign(socket, confirm_delete_resource: true)}
  end

  def handle_event("cancel_delete_resource", _params, socket) do
    {:noreply, assign(socket, confirm_delete_resource: false)}
  end

  def handle_event("delete_resource", _params, socket) do
    resource = socket.assigns.selected_resource

    case Database.delete_resource(resource, socket.assigns.subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Resource \"#{resource.name}\" was deleted.")
         |> reload_live_table!("resources")
         |> push_patch(to: ~p"/#{socket.assigns.account}/resources")}

      {:error, _} ->
        {:noreply, assign(socket, confirm_delete_resource: false)}
    end
  end

  def handle_event("confirm_remove_group", %{"group_id" => group_id}, socket) do
    {:noreply, assign(socket, confirm_remove_group_id: group_id, group_actions_open_id: nil)}
  end

  def handle_event("cancel_remove_group", _params, socket) do
    {:noreply, assign(socket, confirm_remove_group_id: nil)}
  end

  def handle_event("remove_group_access", %{"group_id" => group_id}, socket) do
    resource = socket.assigns.selected_resource

    case Database.delete_policy_for_group(resource, group_id, socket.assigns.subject) do
      {:ok, _} ->
        groups = Database.list_groups_for_resource(resource, socket.assigns.subject)

        {:noreply,
         socket
         |> assign(
           selected_groups: groups,
           confirm_remove_group_id: nil,
           group_actions_open_id: nil
         )
         |> reload_live_table!("resources")}

      {:error, _} ->
        {:noreply, assign(socket, confirm_remove_group_id: nil)}
    end
  end

  def handle_event("toggle_conditions_dropdown", _params, socket) do
    {:noreply, assign(socket, conditions_dropdown_open: !socket.assigns.conditions_dropdown_open)}
  end

  def handle_event("add_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     assign(socket,
       active_conditions: socket.assigns.active_conditions ++ [type],
       conditions_dropdown_open: false
     )}
  end

  def handle_event("remove_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     assign(socket, active_conditions: List.delete(socket.assigns.active_conditions, type))}
  end

  def handle_info(%Change{old_struct: %Resource{}}, socket) do
    {:noreply, reload_live_table!(socket, "resources")}
  end

  def handle_info(%Change{struct: %Resource{}}, socket) do
    {:noreply, reload_live_table!(socket, "resources")}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: event}, socket)
      when event in ["presence_diff", "presence_state"] do
    {:noreply, reload_live_table!(socket, "resources")}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  attr :open, :boolean, required: true
  slot :inner_block, required: true

  defp resource_filter_ports(nil), do: %{}

  defp resource_filter_ports(%Phoenix.HTML.Form{source: nil}), do: %{}

  defp resource_filter_ports(%Phoenix.HTML.Form{source: source}) do
    source
    |> Ecto.Changeset.get_field(:filters, [])
    |> Map.new(fn f -> {f.protocol, Enum.join(f.ports, ", ")} end)
  end

  defp resource_filter_ports(_), do: %{}

  defp resource_form_panel_state(assigns) do
    %{
      resource_form: assigns.resource_form,
      resource_form_sites: assigns.resource_form_sites,
      resource_form_active_protocols: assigns.resource_form_active_protocols,
      resource_form_filters_dropdown_open: assigns.resource_form_filters_dropdown_open,
      resource_form_selected_clients: assigns.resource_form_selected_clients,
      resource_form_client_search: assigns.resource_form_client_search,
      resource_form_client_search_results: assigns.resource_form_client_search_results,
      client_to_client_enabled: assigns.client_to_client_enabled?,
      filter_ports: resource_filter_ports(assigns.resource_form)
    }
  end

  defp resource_grant_panel_state(assigns) do
    %{
      available_groups: assigns.available_groups,
      providers: assigns.providers,
      timezone: assigns.timezone,
      grant_group_id: assigns.grant_group_id,
      grant_form: assigns.grant_form,
      grant_search: assigns.grant_search,
      location_search: assigns.location_search,
      location_operator: assigns.location_operator,
      location_values: assigns.location_values,
      ip_range_operator: assigns.ip_range_operator,
      ip_range_values: assigns.ip_range_values,
      ip_range_input: assigns.ip_range_input,
      auth_provider_operator: assigns.auth_provider_operator,
      auth_provider_values: assigns.auth_provider_values,
      active_conditions: assigns.active_conditions,
      conditions_dropdown_open: assigns.conditions_dropdown_open
    }
  end

  defp resource_panel_ui_state(assigns) do
    %{
      confirm_remove_group_id: assigns.confirm_remove_group_id,
      group_actions_open_id: assigns.group_actions_open_id,
      confirm_delete_resource: assigns.confirm_delete_resource
    }
  end

  defp panel_shell(assigns) do
    ~H"""
    <div
      id="resource-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@open, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :resource, :any, default: nil
  attr :panel_view, :atom, required: true
  attr :form_state, :map, required: true

  defp resource_form_panel(assigns) do
    assigns = assign(assigns, assigns.form_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-[var(--text-primary)]">
            {if @panel_view == :new_form, do: "Add Resource", else: "Edit Resource"}
          </h2>
          <button
            phx-click="cancel_resource_form"
            class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <.icon name="remix-close-line" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <.form
        for={@resource_form}
        phx-submit="submit_resource_form"
        phx-change="change_resource_form"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <.resource_type_picker
            form={@resource_form}
            resource={@resource}
            client_to_client_enabled={@client_to_client_enabled}
          />

          <.resource_core_fields form={@resource_form} resource={@resource} />

          <.resource_device_pool_section
            :if={to_string(@resource_form[:type].value) == "static_device_pool"}
            selected_clients={@resource_form_selected_clients}
            client_search={@resource_form_client_search}
            client_search_results={@resource_form_client_search_results}
          />

          <.resource_dns_ip_stack_section
            :if={"#{@resource_form[:type].value}" == "dns"}
            form={@resource_form}
          />

          <.resource_traffic_restrictions_section
            resource={@resource}
            form={@resource_form}
            active_protocols={@resource_form_active_protocols}
            filters_dropdown_open={@resource_form_filters_dropdown_open}
            filter_ports={@filter_ports}
          />

          <.resource_site_selector form={@resource_form} sites={@resource_form_sites} />
        </div>

        <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
          <button
            type="button"
            phx-click="cancel_resource_form"
            class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
          >
            {if @panel_view == :new_form, do: "Create Resource", else: "Save Changes"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :resource, :any, required: true
  attr :groups, :list, default: []
  attr :panel_view, :atom, required: true
  attr :grant_state, :map, required: true
  attr :ui_state, :map, required: true

  defp resource_details_panel(assigns) do
    assigns = assign(assigns, assigns.ui_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">{@resource.name}</h2>
              <span class={type_badge_class(@resource.type)}>
                {resource_type_label(@resource.type)}
              </span>
              <.status_badge status={if resource_online?(@resource), do: :online, else: :offline} />
            </div>
            <div :if={@resource.type != :internet} class="flex items-center gap-1.5 mt-1">
              <span class="font-mono text-xs text-[var(--text-secondary)]">
                {@resource.address}
              </span>
            </div>
            <p class={[
              "text-xs mt-1",
              if(@resource.address_description,
                do: "text-[var(--text-tertiary)]",
                else: "text-[var(--text-muted)] italic"
              )
            ]}>
              {@resource.address_description || "No Address Description"}
            </p>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              :if={not @confirm_delete_resource && @resource.type != :internet}
              phx-click="open_edit_form"
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
      </div>
      <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
        <div class="flex-1 flex flex-col overflow-hidden">
          <.resource_access_list
            :if={@panel_view == :list}
            account={@account}
            groups={@groups}
            ui_state={@ui_state}
          />
          <.resource_grant_form
            :if={@panel_view == :grant_form}
            resource={@resource}
            grant_state={@grant_state}
          />
        </div>
        <.resource_sidebar
          account={@account}
          resource={@resource}
          ui_state={@ui_state}
        />
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :groups, :list, default: []
  attr :ui_state, :map, required: true

  defp resource_access_list(assigns) do
    assigns = assign(assigns, assigns.ui_state)

    ~H"""
    <div class="flex items-center justify-between px-5 py-2.5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-[var(--text-primary)]">
          Groups with access
        </span>
        <span class="text-xs text-[var(--text-tertiary)]">{length(@groups)}</span>
      </div>
      <button
        phx-click="open_grant_form"
        class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
      >
        <.icon name="remix-add-line" class="w-3 h-3" /> Grant access
      </button>
    </div>
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li
          :for={group <- @groups}
          class={[
            "border-b border-[var(--border)] transition-colors",
            if(@group_actions_open_id == group.id, do: "relative z-20", else: "")
          ]}
        >
          <div
            :if={@confirm_remove_group_id == group.id}
            class="flex items-center justify-between gap-2 px-4 py-2.5 bg-[var(--surface-raised)]"
          >
            <span class="text-xs text-[var(--text-secondary)] truncate">
              Remove <span class="font-medium text-[var(--text-primary)]">{group.name}</span>'s access?
              <span class="block text-[var(--text-tertiary)]">
                All group members will immediately lose access.
              </span>
            </span>
            <div class="flex items-center gap-1.5 shrink-0">
              <button
                type="button"
                phx-click="cancel_remove_group"
                class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
              >
                Cancel
              </button>
              <button
                type="button"
                phx-click="remove_group_access"
                phx-value-group_id={group.id}
                class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/30 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors"
              >
                Remove
              </button>
            </div>
          </div>
          <div
            :if={@confirm_remove_group_id != group.id}
            class={[
              "flex items-center gap-1 pr-4 hover:bg-[var(--surface-raised)] group/item",
              if(not is_nil(group.policy_disabled_at),
                do: "opacity-50 hover:opacity-75",
                else: ""
              )
            ]}
          >
            <.link
              navigate={~p"/#{@account}/groups/#{group.id}"}
              class="flex items-center gap-3 px-5 py-3 flex-1 min-w-0"
            >
              <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4" />
              </div>
              <div class="flex-1 min-w-0 flex items-center gap-2">
                <p class="text-sm font-medium text-[var(--text-primary)] group-hover/item:text-[var(--brand)] transition-colors truncate">
                  {group.name}
                </p>
                <span
                  :if={not is_nil(group.policy_disabled_at)}
                  class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)]"
                >
                  disabled
                </span>
              </div>
            </.link>
            <div class="relative shrink-0">
              <button
                type="button"
                phx-click="toggle_group_actions"
                phx-value-group_id={group.id}
                class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface)] transition-colors"
                title="More actions"
              >
                <.icon name="remix-more-2-line" class="w-3.5 h-3.5" />
              </button>
              <div
                :if={@group_actions_open_id == group.id}
                phx-click-away="close_group_actions"
                class="absolute right-0 top-full mt-1 w-40 rounded-md border border-[var(--border)] bg-[var(--surface-overlay)] shadow-lg z-10 py-1"
              >
                <button
                  :if={is_nil(group.policy_disabled_at)}
                  type="button"
                  phx-click="disable_policy"
                  phx-value-group_id={group.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-pause-line" class="w-3.5 h-3.5 shrink-0" /> Disable
                </button>
                <button
                  :if={not is_nil(group.policy_disabled_at)}
                  type="button"
                  phx-click="enable_policy"
                  phx-value-group_id={group.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-play-line" class="w-3.5 h-3.5 shrink-0" /> Enable
                </button>
                <button
                  type="button"
                  phx-click="confirm_remove_group"
                  phx-value-group_id={group.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-[var(--status-error)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Remove access
                </button>
              </div>
            </div>
          </div>
        </li>
      </ul>
      <div
        :if={@groups == []}
        class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
      >
        No groups have access yet.
      </div>
    </div>
    """
  end

  attr :resource, :any, required: true
  attr :grant_state, :map, required: true

  defp resource_grant_form(assigns) do
    assigns = assign(assigns, assigns.grant_state)

    ~H"""
    <div class="flex items-center justify-between px-5 py-2.5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="close_grant_form"
          class="flex items-center justify-center w-5 h-5 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface)] transition-colors"
          title="Back to group list"
        >
          <.icon name="remix-arrow-left-s-line" class="w-3.5 h-3.5" />
        </button>
        <span class="text-xs font-semibold text-[var(--text-primary)]">Grant access</span>
      </div>
      <span class="text-xs text-[var(--text-tertiary)]">
        {length(@available_groups)} available
      </span>
    </div>
    <.form
      for={@grant_form}
      phx-submit="submit_grant"
      id="grant-form"
      class="flex-1 flex flex-col overflow-hidden"
    >
      <input type="hidden" name="policy[group_id]" value={@grant_group_id} />
      <div class="flex-1 overflow-y-auto">
        <div class="px-5 py-4 space-y-5">
          <div>
            <label class="block text-xs font-medium text-[var(--text-secondary)] mb-2">
              Group <span class="text-[var(--status-error)]">*</span>
            </label>
            <div class="relative mb-2">
              <.icon
                name="remix-search-line"
                class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-[var(--text-tertiary)] pointer-events-none"
              />
              <input
                type="text"
                placeholder="Filter groups…"
                value={@grant_search}
                phx-keyup="search_grant_groups"
                phx-debounce="200"
                class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-[var(--border)] bg-[var(--surface-raised)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors"
              />
            </div>
            <% filtered_groups =
              if @grant_search == "" do
                Enum.take(@available_groups, 5)
              else
                @available_groups
                |> Enum.filter(fn g ->
                  String.contains?(
                    String.downcase(g.name),
                    String.downcase(@grant_search)
                  )
                end)
                |> Enum.take(5)
              end %>
            <ul class="space-y-1">
              <li :for={group <- filtered_groups}>
                <button
                  type="button"
                  phx-click="select_grant_group"
                  phx-value-group_id={group.id}
                  class={[
                    "flex items-center gap-3 px-3 py-2.5 w-full rounded-lg border cursor-pointer transition-colors",
                    if @grant_group_id == group.id do
                      "border-[var(--brand)] bg-[var(--brand-muted)]"
                    else
                      "border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)]"
                    end
                  ]}
                >
                  <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                    <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4" />
                  </div>
                  <div class="flex-1 min-w-0">
                    <p class={[
                      "text-sm font-medium truncate transition-colors",
                      if(@grant_group_id == group.id,
                        do: "text-[var(--brand)]",
                        else: "text-[var(--text-primary)]"
                      )
                    ]}>
                      {group.name}
                    </p>
                  </div>
                  <.icon
                    :if={@grant_group_id == group.id}
                    name="remix-check-line"
                    class="w-4 h-4 text-[var(--brand)] shrink-0"
                  />
                </button>
              </li>
            </ul>
            <div
              :if={@available_groups == []}
              class="flex items-center justify-center h-24 text-sm text-[var(--text-tertiary)]"
            >
              All groups already have access.
            </div>
            <div
              :if={@available_groups != [] && filtered_groups == []}
              class="flex items-center justify-center h-16 text-sm text-[var(--text-tertiary)]"
            >
              No groups match your search.
            </div>
            <p
              :if={length(@available_groups) > 5 && filtered_groups != []}
              class="mt-2 text-center text-[10px] text-[var(--text-muted)]"
            >
              Showing {length(filtered_groups)} of {length(@available_groups)} — type to narrow results
            </p>
          </div>
          <div class="border-t border-[var(--border)] pt-4">
            <div class="flex items-center justify-between mb-3">
              <h4 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Conditions
                <span class="ml-1 font-normal normal-case tracking-normal text-[var(--text-muted)]">
                  (optional)
                </span>
              </h4>
              <div
                :if={available_conditions(@resource) -- @active_conditions != []}
                class="relative"
              >
                <button
                  type="button"
                  phx-click="toggle_conditions_dropdown"
                  class="flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="remix-add-line" class="w-2.5 h-2.5" /> Add condition
                </button>
                <div :if={@conditions_dropdown_open}>
                  <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
                  <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-[var(--border-strong)] bg-[var(--surface-overlay)] shadow-lg py-1 overflow-hidden">
                    <button
                      :for={type <- available_conditions(@resource) -- @active_conditions}
                      type="button"
                      phx-click="add_condition"
                      phx-value-type={type}
                      class="w-full text-left px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                    >
                      {condition_type_label(type)}
                    </button>
                  </div>
                </div>
              </div>
            </div>
            <p
              :if={@active_conditions == []}
              class="text-xs text-[var(--text-muted)] text-center py-4 rounded-lg border border-dashed border-[var(--border)]"
            >
              No conditions — access is unrestricted
            </p>
            <div class="space-y-2">
              <.grant_condition_card
                :for={type <- @active_conditions}
                type={type}
                providers={@providers}
                timezone={@timezone}
                location_search={@location_search}
                location_operator={@location_operator}
                location_values={@location_values}
                ip_range_operator={@ip_range_operator}
                ip_range_values={@ip_range_values}
                ip_range_input={@ip_range_input}
                auth_provider_operator={@auth_provider_operator}
                auth_provider_values={@auth_provider_values}
              />
            </div>
          </div>
        </div>
      </div>
      <div
        :if={@grant_form && @grant_form.errors != []}
        class="px-5 py-2 text-xs text-[var(--status-error)]"
      >
        <p :for={{_field, {msg, _}} <- @grant_form.errors}>{msg}</p>
      </div>
      <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
        <button
          type="button"
          phx-click="close_grant_form"
          class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={is_nil(@grant_group_id)}
          class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed"
        >
          Grant access
        </button>
      </div>
    </.form>
    """
  end

  attr :account, :any, required: true
  attr :resource, :any, required: true
  attr :ui_state, :map, required: true

  defp resource_sidebar(assigns) do
    assigns = assign(assigns, assigns.ui_state)

    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
          Details
        </h3>
        <dl class="space-y-2.5">
          <div>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Resource ID</dt>
            <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
              {@resource.id}
            </dd>
          </div>
          <div>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Type</dt>
            <dd>
              <span class={type_badge_class(@resource.type)}>
                {resource_type_label(@resource.type)}
              </span>
            </dd>
          </div>
          <div :if={@resource.type == :dns}>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">IP Stack</dt>
            <dd class="text-xs text-[var(--text-secondary)]">
              {case @resource.ip_stack do
                :dual -> "Dual-stack (A + AAAA)"
                :ipv4_only -> "IPv4 only (A)"
                :ipv6_only -> "IPv6 only (AAAA)"
                _ -> "Dual-stack (A + AAAA)"
              end}
            </dd>
          </div>
          <div :if={@resource.type not in [:internet, :static_device_pool]}>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Address</dt>
            <dd class="font-mono text-xs text-[var(--text-primary)] font-medium break-all">
              {@resource.address}
            </dd>
          </div>
          <div :if={@resource.type == :static_device_pool}>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Address</dt>
            <dd class="text-xs italic text-[var(--text-muted)]">Multiple Addresses</dd>
          </div>
          <div>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Description</dt>
            <dd class={[
              "text-xs",
              if(@resource.address_description,
                do: "text-[var(--text-secondary)]",
                else: "text-[var(--text-muted)] italic"
              )
            ]}>
              {@resource.address_description || "No Address Description"}
            </dd>
          </div>
        </dl>
      </section>
      <div :if={@resource.type != :internet} class="border-t border-[var(--border)]"></div>
      <section :if={@resource.type != :internet}>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
          Traffic Restrictions
        </h3>
        <p
          :if={@resource.filters == []}
          class="text-xs text-[var(--text-muted)] italic"
        >
          None — all protocols/ports permitted
        </p>
        <ul :if={@resource.filters != []} class="space-y-1">
          <li
            :for={filter <- @resource.filters}
            class="text-xs font-mono text-[var(--text-secondary)]"
          >
            {format_filter(filter)}
          </li>
        </ul>
      </section>
      <div class="border-t border-[var(--border)]"></div>
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
          Infrastructure
        </h3>
        <dl class="space-y-2.5">
          <div :if={@resource.type == :static_device_pool}>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-1">Site</dt>
            <dd class="text-xs italic text-[var(--text-muted)]">No Site Needed</dd>
          </div>
          <div :if={@resource.site && @resource.type != :static_device_pool}>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-1">Site</dt>
            <dd class="flex items-center gap-1.5 flex-wrap">
              <.link
                navigate={~p"/#{@account}/sites/#{@resource.site}"}
                class="text-xs font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
              >
                {@resource.site.name}
              </.link>
              <span
                :if={resource_online?(@resource)}
                class="relative flex items-center justify-center w-1.5 h-1.5"
              >
                <span class="absolute inline-flex rounded-full opacity-60 animate-ping w-1.5 h-1.5 bg-[var(--status-active)]">
                </span>
                <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-[var(--status-active)]">
                </span>
              </span>
            </dd>
          </div>
        </dl>
      </section>
      <div class="border-t border-[var(--border)]"></div>
      <section :if={@resource.type != :internet}>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
          Danger Zone
        </h3>
        <button
          :if={not @confirm_delete_resource}
          type="button"
          phx-click="confirm_delete_resource"
          class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
        >
          Delete resource
        </button>
        <div
          :if={@confirm_delete_resource}
          class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
        >
          <p class="text-xs font-medium text-[var(--status-error)] mb-1">
            Delete this resource?
          </p>
          <p class="text-xs text-[var(--status-error)]/70 mb-3">
            All associated policies will also be deleted and clients will immediately lose access.
          </p>
          <div class="flex items-center gap-1.5">
            <button
              type="button"
              phx-click="cancel_delete_resource"
              class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="button"
              phx-click="delete_resource"
              class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
            >
              Delete
            </button>
          </div>
        </div>
      </section>
    </div>
    """
  end

  @spec format_filter(map()) :: String.t()
  defp format_filter(%{protocol: :icmp}), do: "ICMP: Allowed"

  defp format_filter(%{protocol: protocol, ports: []}),
    do: "#{String.upcase("#{protocol}")}: All ports"

  defp format_filter(%{protocol: protocol, ports: ports}),
    do: "#{String.upcase("#{protocol}")}: #{Enum.join(ports, ", ")}"

  @spec maybe_put_default_name(map(), boolean()) :: map()
  defp maybe_put_default_name(attrs, true), do: attrs
  defp maybe_put_default_name(attrs, false), do: Map.put(attrs, "name", attrs["address"])

  @spec to_grant_form() :: Phoenix.HTML.Form.t()
  defp to_grant_form do
    %Portal.Policy{}
    |> Ecto.Changeset.change()
    |> to_form(as: :policy)
  end

  @spec resource_online?(map()) :: boolean()
  defp resource_online?(%{site_id: nil}), do: false

  defp resource_online?(%{site_id: site_id}) do
    Presence.Gateways.Site.list(site_id) |> map_size() > 0
  end

  @spec resource_type_label(atom()) :: String.t()
  defp resource_type_label(:dns), do: "DNS"
  defp resource_type_label(:ip), do: "IP"
  defp resource_type_label(:cidr), do: "CIDR"
  defp resource_type_label(:internet), do: "Internet"
  defp resource_type_label(:static_device_pool), do: "Device Pool"
  defp resource_type_label(type), do: to_string(type)

  @spec type_badge_class(atom()) :: String.t()
  defp type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-dns-bg)] text-[var(--badge-dns-text)]"

  defp type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-ip-bg)] text-[var(--badge-ip-text)]"

  defp type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-cidr-bg)] text-[var(--badge-cidr-text)]"

  defp type_badge_class(:internet),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium trcking-wider uppercase bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  defp type_badge_class(:static_device_pool),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-device-pool-bg)] text-[var(--badge-device-pool-text)]"

  defp type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--surface-raised)] text-[var(--text-secondary)]"

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    import Portal.Repo.Query
    alias Portal.Safe
    alias Portal.Resource
    alias Portal.StaticDevicePoolMember
    alias Portal.Policy
    alias Portal.Site
    alias Portal.Group
    alias Portal.Directory
    alias PortalWeb.Resources.Components

    defdelegate client_to_client_enabled?(account), to: Components.Database
    defdelegate get_client(client_id, subject), to: Components.Database
    defdelegate search_clients(search_term, subject, selected_clients), to: Components.Database

    def all_sites(subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def new_resource(account, attrs \\ %{}) do
      changeset =
        %Resource{}
        |> cast(attrs, [:name, :address, :address_description, :type, :ip_stack, :site_id])
        |> put_change(:account_id, account.id)
        |> Resource.changeset()

      if get_field(changeset, :type) == :static_device_pool do
        validate_required(changeset, [:name])
      else
        validate_required(changeset, [:name, :address])
      end
    end

    def create_resource(attrs, selected_clients, subject) do
      changeset =
        new_resource(subject.account, attrs)
        |> maybe_validate_required_fields()
        |> Components.Database.validate_static_device_pool_feature_enabled(subject.account)

      with {:ok, validated_clients} <-
             Components.Database.validate_selected_clients(selected_clients, subject),
           {:ok, resource} <- Safe.scoped(changeset, subject) |> Safe.insert(),
           :ok <-
             Components.Database.sync_static_pool_members(resource, validated_clients, subject) do
        {:ok, resource}
      else
        {:error, %Ecto.Changeset{} = cs} ->
          {:error, cs}

        {:error, :invalid_clients} ->
          {:error, add_error(changeset, :name, "one or more selected clients are invalid")}

        {:error, :unauthorized} ->
          {:error, add_error(changeset, :name, "you are not authorized to perform this action")}
      end
    end

    defp maybe_validate_required_fields(changeset) do
      if get_field(changeset, :type) == :static_device_pool do
        validate_required(changeset, [:name])
      else
        validate_required(changeset, [:site_id])
      end
    end

    def change_resource(resource, attrs \\ %{}) do
      update_fields = ~w[address address_description name type ip_stack site_id]a

      changeset =
        resource
        |> cast(attrs, update_fields)
        |> Resource.changeset()

      if get_field(changeset, :type) == :static_device_pool do
        validate_required(changeset, [:name, :type])
      else
        validate_required(changeset, [:name, :type, :site_id])
      end
    end

    def update_resource(resource, attrs, selected_clients, subject) do
      changeset =
        change_resource(resource, attrs)
        |> Components.Database.validate_static_device_pool_feature_enabled(subject.account)

      with {:ok, validated_clients} <-
             Components.Database.validate_selected_clients(selected_clients, subject),
           {:ok, updated_resource} <- Safe.scoped(changeset, subject) |> Safe.update(),
           :ok <-
             Components.Database.sync_static_pool_members(
               updated_resource,
               validated_clients,
               subject
             ) do
        {:ok, updated_resource}
      else
        {:error, %Ecto.Changeset{} = cs} ->
          {:error, cs}

        {:error, :invalid_clients} ->
          {:error, add_error(changeset, :name, "one or more selected clients are invalid")}

        {:error, :unauthorized} ->
          {:error, add_error(changeset, :name, "you are not authorized to perform this action")}
      end
    end

    def list_pool_members(%Resource{type: :static_device_pool} = resource, subject) do
      client_ids =
        from(m in StaticDevicePoolMember,
          where: m.resource_id == ^resource.id,
          select: m.client_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, _} -> []
          ids -> ids
        end

      from(c in Portal.Client, as: :clients)
      |> where([clients: c], c.id in ^client_ids)
      |> preload([:ipv4_address, :ipv6_address])
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        clients -> Portal.Presence.Clients.preload_clients_presence(clients)
      end
    end

    def list_pool_members(_resource, _subject), do: []

    def get_resource!(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> preload(:site)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_internet_resource(subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.type == :internet)
      |> preload(:site)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def list_resources(subject, opts \\ []) do
      from(resources in Resource, as: :resources)
      |> where([resources: r], r.type != :internet)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def count_policies_for_resources(resources, subject) do
      ids = resources |> Enum.map(& &1.id) |> Enum.uniq()

      from(p in Policy, as: :policies)
      |> where([policies: p], p.resource_id in ^ids)
      |> where([policies: p], is_nil(p.disabled_at))
      |> group_by([policies: p], p.resource_id)
      |> select([policies: p], {p.resource_id, count(p.id)})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} -> %{}
        counts -> Map.new(counts)
      end
    end

    def list_groups_for_resource(resource, subject) do
      from(g in Group, as: :groups)
      |> join(:inner, [groups: g], p in Policy,
        on: p.group_id == g.id and p.resource_id == ^resource.id,
        as: :policies
      )
      |> join(:left, [groups: g], d in Directory,
        on: d.id == g.directory_id and d.account_id == g.account_id,
        as: :directory
      )
      |> select_merge([groups: g, directory: d, policies: p], %{
        directory_type: d.type,
        policy_id: p.id,
        policy_disabled_at: p.disabled_at
      })
      |> order_by([policies: p], desc: is_nil(p.disabled_at))
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        groups -> groups
      end
    end

    def list_available_groups(_resource, existing_group_ids, subject) do
      from(g in Group, as: :groups)
      |> where([groups: g], g.id not in ^existing_group_ids)
      |> join(:left, [groups: g], d in Directory,
        on: d.id == g.directory_id and d.account_id == g.account_id,
        as: :directory
      )
      |> select_merge([groups: g, directory: d], %{directory_type: d.type})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        groups -> groups
      end
    end

    def insert_policy(attrs, subject) do
      changeset =
        %Portal.Policy{}
        |> cast(attrs, ~w[description group_id resource_id]a)
        |> validate_required(~w[group_id resource_id]a)
        |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
        |> Portal.Policy.changeset()
        |> put_change(:account_id, subject.account.id)
        |> populate_group_idp_id(subject)

      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    def delete_resource(resource, subject) do
      Safe.scoped(resource, subject)
      |> Safe.delete()
    end

    def delete_policy_for_group(resource, group_id, subject) do
      from(p in Policy, as: :policies)
      |> where(
        [policies: p],
        p.resource_id == ^resource.id and p.group_id == ^group_id
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(&(Safe.scoped(&1, subject) |> Safe.delete()))
    end

    def disable_policy_for_group(resource, group_id, subject) do
      from(p in Policy, as: :policies)
      |> where(
        [policies: p],
        p.resource_id == ^resource.id and p.group_id == ^group_id and is_nil(p.disabled_at)
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(fn policy ->
        Ecto.Changeset.change(policy, %{disabled_at: DateTime.utc_now()})
        |> Safe.scoped(subject)
        |> Safe.update()
      end)
    end

    def enable_policy_for_group(resource, group_id, subject) do
      from(p in Policy, as: :policies)
      |> where(
        [policies: p],
        p.resource_id == ^resource.id and p.group_id == ^group_id and not is_nil(p.disabled_at)
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(fn policy ->
        Ecto.Changeset.change(policy, %{disabled_at: nil})
        |> Safe.scoped(subject)
        |> Safe.update()
      end)
    end

    def list_providers(subject) do
      [
        Portal.Userpass.AuthProvider,
        Portal.EmailOTP.AuthProvider,
        Portal.OIDC.AuthProvider,
        Portal.Google.AuthProvider,
        Portal.Entra.AuthProvider,
        Portal.Okta.AuthProvider
      ]
      |> Enum.flat_map(fn schema ->
        from(p in schema, where: not p.is_disabled)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
      end)
    end

    defp populate_group_idp_id(changeset, subject) do
      case get_change(changeset, :group_id) do
        nil ->
          changeset

        group_id ->
          idp_id =
            from(g in Group, where: g.id == ^group_id, select: g.idp_id)
            |> Safe.scoped(subject, :replica)
            |> Safe.one()

          put_change(changeset, :group_idp_id, idp_id)
      end
    end

    def cursor_fields do
      [
        {:resources, :asc, :name},
        {:resources, :asc, :inserted_at},
        {:resources, :asc, :id}
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name_or_address,
          title: "Name or Address",
          type: {:string, :websearch},
          fun: &filter_by_name_fts_or_address/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
          name: :type,
          title: "Type",
          type: :string,
          values: [
            {"DNS", "dns"},
            {"IP", "ip"},
            {"CIDR", "cidr"},
            {"Device Pool", "static_device_pool"}
          ],
          fun: &filter_by_type/2
        }
      ]
    end

    def filter_by_name_fts_or_address(queryable, name_or_address) do
      {queryable,
       dynamic(
         [resources: resources],
         fulltext_search(resources.name, ^name_or_address) or
           fulltext_search(resources.address, ^name_or_address)
       )}
    end

    def filter_by_site_id(queryable, site_id) do
      {queryable, dynamic([resources: r], r.site_id == ^site_id)}
    end

    def filter_by_type(queryable, type) do
      {queryable, dynamic([resources: r], r.type == ^String.to_existing_atom(type))}
    end
  end
end
