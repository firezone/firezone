# credo:disable-for-this-file Credo.Check.Warning.CrossModuleDatabaseCall
defmodule PortalWeb.Resources do
  use PortalWeb, :live_view

  import PortalWeb.Policies.Components,
    only: [
      map_condition_params: 2,
      maybe_drop_unsupported_conditions: 2
    ]

  import PortalWeb.Resources.Components,
    only: [
      map_filters_form_attrs: 2,
      panel_shell: 1,
      resource_details_panel: 1,
      resource_form_panel: 1,
      resource_online?: 1,
      resource_type_label: 1,
      type_badge_class: 1,
      to_grant_form: 0
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
      |> assign(resource_state_assigns(socket))
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
     socket
     |> assign(filter_site: filter_site, selected_resource: resource, selected_groups: groups)
     |> assign(show_resource_state_assigns(socket))}
  end

  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    sites = Database.all_sites(socket.assigns.subject)
    changeset = Database.new_resource(socket.assigns.account)
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(filter_site: nil, selected_resource: nil, selected_groups: [])
     |> assign(new_resource_state_assigns(socket, to_form(changeset), sites))}
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
       socket
       |> assign(filter_site: nil, selected_resource: resource, selected_groups: [])
       |> assign(
         edit_resource_state_assigns(
           socket,
           to_form(changeset),
           sites,
           resource,
           selected_clients
         )
       )}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    filter_site = filter_site_from_params(params, socket.assigns.subject)

    {:noreply,
     socket
     |> assign(filter_site: filter_site, selected_resource: nil, selected_groups: [])
     |> assign(resource_state_assigns(socket))}
  end

  defp resource_state_assigns(socket) do
    [
      resource_panel: base_resource_panel(socket),
      resource_form: base_resource_form(nil, []),
      resource_grant: base_resource_grant(socket),
      resource_ui: base_resource_ui()
    ]
  end

  defp show_resource_state_assigns(socket), do: resource_state_assigns(socket)

  defp new_resource_state_assigns(socket, resource_form, sites) do
    [
      resource_panel: base_resource_panel(socket, view: :new_form),
      resource_form: base_resource_form(resource_form, sites),
      resource_grant: base_resource_grant(socket),
      resource_ui: base_resource_ui()
    ]
  end

  defp edit_resource_state_assigns(socket, resource_form, sites, resource, selected_clients) do
    [
      resource_panel: base_resource_panel(socket, view: :edit_form),
      resource_form:
        base_resource_form(resource_form, sites,
          active_protocols: Enum.map(resource.filters, & &1.protocol),
          selected_clients: selected_clients
        ),
      resource_grant: base_resource_grant(socket),
      resource_ui: base_resource_ui()
    ]
  end

  defp base_resource_panel(socket, overrides \\ []) do
    connect_params = Map.get(socket.private, :connect_params, %{})

    Enum.into(
      overrides,
      %{
        view: :list,
        timezone: Map.get(connect_params, "timezone", "UTC"),
        client_to_client_enabled?: Database.client_to_client_enabled?(socket.assigns.account)
      }
    )
  end

  defp base_resource_form(resource_form, sites, overrides \\ []) do
    Enum.into(
      overrides,
      %{
        form: resource_form,
        sites: sites,
        address_description_changed?: false,
        active_protocols: [],
        filters_dropdown_open?: false,
        selected_clients: [],
        client_search: "",
        client_search_results: nil
      }
    )
  end

  defp base_resource_grant(socket, overrides \\ []) do
    Enum.into(
      overrides,
      %{
        available_groups: [],
        providers: [],
        timezone: base_resource_panel(socket).timezone,
        grant_selected_group_ids: [],
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
        tod_values: [],
        tod_adding?: false,
        tod_pending: %{"on" => "", "off" => "", "days" => []},
        tod_pending_error: nil
      }
    )
  end

  defp base_resource_ui(overrides \\ []) do
    Enum.into(
      overrides,
      %{
        confirm_remove_group_id: nil,
        group_actions_open_id: nil,
        confirm_delete_resource: false
      }
    )
  end

  defp merge_state(socket, key, attrs) do
    update(socket, key, &Map.merge(&1, Map.new(attrs)))
  end

  @spec valid_tod_range?(String.t(), String.t()) :: boolean()
  defp valid_tod_range?(on, off) do
    with [on_h, on_m | _] <- String.split(on, ":"),
         [off_h, off_m | _] <- String.split(off, ":"),
         {on_h, ""} <- Integer.parse(on_h),
         {on_m, ""} <- Integer.parse(on_m),
         {off_h, ""} <- Integer.parse(off_h),
         {off_m, ""} <- Integer.parse(off_m) do
      on_h * 60 + on_m < off_h * 60 + off_m
    else
      _ -> false
    end
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
    case socket.assigns.resource_panel.view do
      :edit_form -> resource_show_path(socket, socket.assigns.selected_resource.id)
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
          <.icon name="ri-server-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Resources</:title>
        <:description>
          Network endpoints accessible through Firezone.
        </:description>
        <:action>
          <.docs_action path="/deploy/resources" />
          <.button style="primary" icon="ri-add-line" phx-click="open_new_form">
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
                  <.icon name="ri-global-line" class="w-5 h-5 text-violet-500" />
                  <div class="font-semibold transition-colors text-[var(--text-primary)] group-hover:text-[var(--brand)]">
                    Internet Resource
                  </div>
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-200/70 text-violet-700 dark:bg-violet-900/40 dark:text-violet-300">
                    system
                  </span>
                </div>
                <div class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Network traffic outside defined resources
                </div>
              </td>
              <td class="px-4 py-3">
                <span class={type_badge_class(:internet)}>
                  {resource_type_label(:internet)}
                </span>
              </td>
              <td class="px-4 py-3 hidden lg:table-cell">
                <span class="font-mono text-xs text-[var(--text-primary)]">0.0.0.0/0, ::/0</span>
              </td>
              <td class="px-4 py-3">
                <% count = Map.get(@resource_policy_counts, @internet_resource.id, 0) %>
                <.link
                  :if={count > 0}
                  navigate={
                    ~p"/#{@account}/policies?policies_filter[resource_id]=#{@internet_resource.id}"
                  }
                >
                  <span class="inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums bg-[var(--brand-tertiary)] text-[var(--brand)]">
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
              class="font-mono text-xs text-[var(--text-primary)]"
            >
              {resource.address}
            </span>
            <span
              :if={resource.type == :internet}
              class="font-mono text-xs text-[var(--text-primary)]"
            >
              0.0.0.0/0, ::/0
            </span>
            <span
              :if={resource.type == :static_device_pool}
              class="font-mono text-xs italic text-[var(--text-tertiary)]"
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
              <span class="inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums bg-[var(--brand-tertiary)] text-[var(--brand)]">
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
                <.icon name="ri-server-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
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
                <.icon name="ri-add-line" class="w-3 h-3" /> Add a Resource
              </.link>
            </div>
          </:empty>
        </.live_table>
      </div>
      <.panel_shell open={
        not is_nil(@selected_resource) or @resource_panel.view in [:new_form, :edit_form]
      }>
        <%= if @resource_panel.view in [:new_form, :edit_form] do %>
          <.resource_form_panel
            resource={@selected_resource}
            panel_view={@resource_panel.view}
            form_state={resource_form_panel_state(assigns)}
          />
        <% end %>

        <%= if @selected_resource && @resource_panel.view not in [:new_form, :edit_form] do %>
          <.resource_details_panel
            account={@account}
            resource={@selected_resource}
            groups={@selected_groups}
            panel_view={@resource_panel.view}
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
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/resources?#{params}")}
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
    address_description_changed? =
      socket.assigns.resource_form.address_description_changed? ||
        payload["_target"] == ["resource", "address_description"]

    attrs = map_filters_form_attrs(attrs, socket.assigns.account)

    changeset =
      if socket.assigns.resource_panel.view == :new_form do
        Database.new_resource(socket.assigns.account, attrs)
      else
        Database.change_resource(socket.assigns.selected_resource, attrs)
      end
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> merge_state(:resource_form,
       form: to_form(changeset),
       address_description_changed?: address_description_changed?
     )}
  end

  def handle_event("submit_resource_form", %{"resource" => attrs}, socket) do
    attrs = map_filters_form_attrs(attrs, socket.assigns.account)

    if socket.assigns.resource_panel.view == :new_form do
      case Database.create_resource(
             attrs,
             socket.assigns.resource_form.selected_clients,
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
          {:noreply, merge_state(socket, :resource_form, form: to_form(changeset))}
      end
    else
      resource = socket.assigns.selected_resource

      case Database.update_resource(
             resource,
             attrs,
             socket.assigns.resource_form.selected_clients,
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
          {:noreply, merge_state(socket, :resource_form, form: to_form(changeset))}
      end
    end
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.resource_panel.view in [:new_form, :edit_form] do
    {:noreply, push_patch(socket, to: cancel_resource_form_path(socket))}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_resource) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/resources?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_resource_filter", %{"protocol" => protocol}, socket) do
    protocol = String.to_existing_atom(protocol)
    active = socket.assigns.resource_form.active_protocols

    {:noreply,
     merge_state(socket, :resource_form,
       active_protocols: if(protocol in active, do: active, else: active ++ [protocol]),
       filters_dropdown_open?: false
     )}
  end

  def handle_event("remove_resource_filter", %{"protocol" => protocol}, socket) do
    protocol = String.to_existing_atom(protocol)

    {:noreply,
     merge_state(socket, :resource_form,
       active_protocols: List.delete(socket.assigns.resource_form.active_protocols, protocol)
     )}
  end

  def handle_event("toggle_resource_filters_dropdown", _params, socket) do
    {:noreply,
     merge_state(socket, :resource_form,
       filters_dropdown_open?: !socket.assigns.resource_form.filters_dropdown_open?
     )}
  end

  def handle_event("close_resource_filters_dropdown", _params, socket) do
    {:noreply, merge_state(socket, :resource_form, filters_dropdown_open?: false)}
  end

  def handle_event("focus_client_search", _params, socket) do
    results =
      Database.search_clients(
        socket.assigns.resource_form.client_search,
        socket.assigns.subject,
        socket.assigns.resource_form.selected_clients
      )

    {:noreply, merge_state(socket, :resource_form, client_search_results: results)}
  end

  def handle_event("blur_client_search", _params, socket) do
    {:noreply, merge_state(socket, :resource_form, client_search_results: nil)}
  end

  def handle_event("search_client", %{"client_search" => search}, socket) do
    results =
      Database.search_clients(
        search,
        socket.assigns.subject,
        socket.assigns.resource_form.selected_clients
      )

    {:noreply,
     merge_state(socket, :resource_form, client_search: search, client_search_results: results)}
  end

  def handle_event("add_client", %{"client_id" => client_id}, socket) do
    case Database.get_client(client_id, socket.assigns.subject) do
      nil ->
        {:noreply, socket}

      client ->
        selected =
          Enum.uniq_by([client | socket.assigns.resource_form.selected_clients], & &1.id)

        {:noreply,
         merge_state(socket, :resource_form,
           selected_clients: selected,
           client_search: "",
           client_search_results: nil
         )}
    end
  end

  def handle_event("remove_client", %{"client_id" => client_id}, socket) do
    selected =
      Enum.reject(socket.assigns.resource_form.selected_clients, &(&1.id == client_id))

    results =
      Database.search_clients(
        socket.assigns.resource_form.client_search,
        socket.assigns.subject,
        selected
      )

    {:noreply,
     merge_state(socket, :resource_form,
       selected_clients: selected,
       client_search_results: results
     )}
  end

  def handle_event("open_grant_form", _params, socket) do
    resource = socket.assigns.selected_resource
    existing_ids = Enum.map(socket.assigns.selected_groups, & &1.id)
    available = Database.list_available_groups(resource, existing_ids, socket.assigns.subject)
    providers = Database.list_providers(socket.assigns.subject)

    {:noreply,
     socket
     |> merge_state(:resource_panel, view: :grant_form)
     |> assign(
       resource_grant:
         base_resource_grant(socket,
           available_groups: available,
           providers: providers,
           grant_form: to_grant_form()
         )
     )
     |> assign(resource_ui: base_resource_ui())}
  end

  def handle_event("close_grant_form", _params, socket) do
    {:noreply,
     socket
     |> merge_state(:resource_panel, view: :list)
     |> assign(resource_grant: base_resource_grant(socket))
     |> assign(resource_ui: base_resource_ui())}
  end

  def handle_event("search_grant_groups", %{"value" => search}, socket) do
    {:noreply, merge_state(socket, :resource_grant, grant_search: search)}
  end

  def handle_event("update_location_search", %{"_location_search" => search}, socket) do
    {:noreply, merge_state(socket, :resource_grant, location_search: search)}
  end

  def handle_event("change_location_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :resource_grant, location_operator: op)}
  end

  def handle_event("change_ip_range_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :resource_grant, ip_range_operator: op)}
  end

  def handle_event("update_ip_range_input", %{"_ip_range_input" => value}, socket) do
    {:noreply, merge_state(socket, :resource_grant, ip_range_input: value)}
  end

  def handle_event("add_ip_range_value", _params, socket) do
    value = String.trim(socket.assigns.resource_grant.ip_range_input)

    if value != "" and value not in socket.assigns.resource_grant.ip_range_values do
      {:noreply,
       merge_state(socket, :resource_grant,
         ip_range_values: socket.assigns.resource_grant.ip_range_values ++ [value],
         ip_range_input: ""
       )}
    else
      {:noreply, merge_state(socket, :resource_grant, ip_range_input: "")}
    end
  end

  def handle_event("remove_ip_range_value", %{"value" => value}, socket) do
    {:noreply,
     merge_state(socket, :resource_grant,
       ip_range_values: List.delete(socket.assigns.resource_grant.ip_range_values, value)
     )}
  end

  def handle_event("change_auth_provider_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :resource_grant, auth_provider_operator: op)}
  end

  def handle_event("toggle_auth_provider_value", %{"id" => id}, socket) do
    values = socket.assigns.resource_grant.auth_provider_values

    updated =
      if id in values do
        List.delete(values, id)
      else
        values ++ [id]
      end

    {:noreply, merge_state(socket, :resource_grant, auth_provider_values: updated)}
  end

  def handle_event("toggle_location_value", %{"code" => code}, socket) do
    values = socket.assigns.resource_grant.location_values

    updated =
      if code in values do
        List.delete(values, code)
      else
        values ++ [code]
      end

    {:noreply, merge_state(socket, :resource_grant, location_values: updated)}
  end

  def handle_event("start_add_tod_range", _params, socket) do
    {:noreply,
     merge_state(socket, :resource_grant,
       tod_adding?: true,
       tod_pending: %{"on" => "", "off" => "", "days" => []}
     )}
  end

  def handle_event("cancel_tod_range", _params, socket) do
    {:noreply,
     merge_state(socket, :resource_grant,
       tod_adding?: false,
       tod_pending: %{"on" => "", "off" => "", "days" => []},
       tod_pending_error: nil
     )}
  end

  def handle_event("toggle_tod_pending_day", %{"day" => day}, socket) do
    {:noreply,
     update(socket, :resource_grant, fn grant ->
       days = grant.tod_pending["days"]
       updated = if day in days, do: List.delete(days, day), else: days ++ [day]
       Map.put(grant, :tod_pending, Map.put(grant.tod_pending, "days", updated))
     end)}
  end

  def handle_event("confirm_tod_range", _params, socket) do
    pending = socket.assigns.resource_grant.tod_pending
    on = pending["on"] || ""
    off = pending["off"] || ""
    days = pending["days"] || []

    cond do
      days == [] or on == "" or off == "" ->
        {:noreply, merge_state(socket, :resource_grant, tod_pending_error: "Must choose day, on-time, and off-time")}

      not valid_tod_range?(on, off) ->
        {:noreply, merge_state(socket, :resource_grant, tod_pending_error: "End time must be after start time")}

      true ->
        {:noreply,
         update(socket, :resource_grant, fn grant ->
           grant
           |> Map.put(:tod_values, grant.tod_values ++ [pending])
           |> Map.put(:tod_adding?, false)
           |> Map.put(:tod_pending, %{"on" => "", "off" => "", "days" => []})
           |> Map.put(:tod_pending_error, nil)
         end)}
    end
  end

  def handle_event("remove_tod_range", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     update(socket, :resource_grant, fn grant ->
       Map.put(grant, :tod_values, List.delete_at(grant.tod_values, index))
     end)}
  end

  def handle_event("change_tod_pending", params, socket) do
    {:noreply,
     update(socket, :resource_grant, fn grant ->
       updates =
         Map.take(params, ["_tod_on", "_tod_off"])
         |> Map.new(fn
           {"_tod_on", v} -> {"on", v}
           {"_tod_off", v} -> {"off", v}
         end)

       grant
       |> Map.put(:tod_pending, Map.merge(grant.tod_pending, updates))
       |> Map.put(:tod_pending_error, nil)
     end)}
  end

  def handle_event("toggle_grant_group", %{"group_id" => group_id}, socket) do
    selected = socket.assigns.resource_grant.grant_selected_group_ids

    updated =
      if group_id in selected do
        List.delete(selected, group_id)
      else
        if length(selected) < 5 do
          selected ++ [group_id]
        else
          selected
        end
      end

    {:noreply, merge_state(socket, :resource_grant, grant_selected_group_ids: updated)}
  end

  def handle_event("submit_grant", params, socket) do
    resource = socket.assigns.selected_resource
    selected_group_ids = socket.assigns.resource_grant.grant_selected_group_ids
    policy_params = Map.get(params, "policy", %{})

    condition_attrs =
      policy_params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    result =
      Enum.reduce_while(selected_group_ids, :ok, fn group_id, :ok ->
        attrs =
          Map.merge(condition_attrs, %{
            "resource_id" => resource.id,
            "group_id" => group_id
          })

        case Database.insert_policy(attrs, socket.assigns.subject) do
          {:ok, _policy} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)

    case result do
      :ok ->
        groups = Database.list_groups_for_resource(resource, socket.assigns.subject)

        {:noreply,
         socket
         |> assign(selected_groups: groups)
         |> merge_state(:resource_panel, view: :list)
         |> assign(resource_grant: base_resource_grant(socket))
         |> assign(resource_ui: base_resource_ui())
         |> reload_live_table!("resources")}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :resource_grant, grant_form: to_form(changeset, as: :policy))}
    end
  end

  def handle_event("toggle_group_actions", %{"group_id" => id}, socket) do
    current = socket.assigns.resource_ui.group_actions_open_id

    {:noreply,
     merge_state(socket, :resource_ui,
       group_actions_open_id: if(current == id, do: nil, else: id)
     )}
  end

  def handle_event("close_group_actions", _params, socket) do
    {:noreply, merge_state(socket, :resource_ui, group_actions_open_id: nil)}
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

        {:noreply,
         socket
         |> assign(selected_groups: groups)
         |> merge_state(:resource_ui, group_actions_open_id: nil)}

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

        {:noreply,
         socket
         |> assign(selected_groups: groups)
         |> merge_state(:resource_ui, group_actions_open_id: nil)}

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
    {:noreply, merge_state(socket, :resource_ui, confirm_delete_resource: true)}
  end

  def handle_event("cancel_delete_resource", _params, socket) do
    {:noreply, merge_state(socket, :resource_ui, confirm_delete_resource: false)}
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
        {:noreply, merge_state(socket, :resource_ui, confirm_delete_resource: false)}
    end
  end

  def handle_event("confirm_remove_group", %{"group_id" => group_id}, socket) do
    {:noreply,
     merge_state(socket, :resource_ui,
       confirm_remove_group_id: group_id,
       group_actions_open_id: nil
     )}
  end

  def handle_event("cancel_remove_group", _params, socket) do
    {:noreply, merge_state(socket, :resource_ui, confirm_remove_group_id: nil)}
  end

  def handle_event("remove_group_access", %{"group_id" => group_id}, socket) do
    resource = socket.assigns.selected_resource

    case Database.delete_policy_for_group(resource, group_id, socket.assigns.subject) do
      {:ok, _} ->
        groups = Database.list_groups_for_resource(resource, socket.assigns.subject)

        {:noreply,
         socket
         |> assign(selected_groups: groups)
         |> merge_state(:resource_ui, confirm_remove_group_id: nil, group_actions_open_id: nil)
         |> reload_live_table!("resources")}

      {:error, _} ->
        {:noreply, merge_state(socket, :resource_ui, confirm_remove_group_id: nil)}
    end
  end

  def handle_event("toggle_conditions_dropdown", _params, socket) do
    {:noreply,
     merge_state(socket, :resource_grant,
       conditions_dropdown_open: !socket.assigns.resource_grant.conditions_dropdown_open
     )}
  end

  def handle_event("add_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     merge_state(socket, :resource_grant,
       active_conditions: socket.assigns.resource_grant.active_conditions ++ [type],
       conditions_dropdown_open: false
     )}
  end

  def handle_event("remove_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     merge_state(socket, :resource_grant,
       active_conditions: List.delete(socket.assigns.resource_grant.active_conditions, type)
     )}
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
      resource_form: assigns.resource_form.form,
      resource_form_sites: assigns.resource_form.sites,
      resource_form_active_protocols: assigns.resource_form.active_protocols,
      resource_form_filters_dropdown_open: assigns.resource_form.filters_dropdown_open?,
      resource_form_selected_clients: assigns.resource_form.selected_clients,
      resource_form_client_search: assigns.resource_form.client_search,
      resource_form_client_search_results: assigns.resource_form.client_search_results,
      client_to_client_enabled: assigns.resource_panel.client_to_client_enabled?,
      filter_ports: resource_filter_ports(assigns.resource_form.form)
    }
  end

  defp resource_grant_panel_state(assigns) do
    assigns.resource_grant
  end

  defp resource_panel_ui_state(assigns) do
    assigns.resource_ui
  end

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
          select: m.device_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, _} -> []
          ids -> ids
        end

      from(c in Portal.Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> where([devices: d], d.id in ^client_ids)
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
      |> Safe.list_offset(__MODULE__, opts)
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
