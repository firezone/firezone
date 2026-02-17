defmodule PortalWeb.Groups do
  use PortalWeb, :live_view

  alias __MODULE__.Database

  @member_page_size 10

  import Ecto.Changeset

  import PortalWeb.Policies.Components,
    only: [
      map_condition_params: 2,
      maybe_drop_unsupported_conditions: 2,
      grant_condition_card: 1,
      available_conditions: 1,
      condition_type_label: 1
    ]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Groups")
      |> assign(groups_with_policies_count: 0)
      |> assign(
        selected_group: nil,
        panel_view: :list,
        confirm_delete: false,
        form: nil,
        group_panel_tab: :members,
        group_resources: [],
        resources_tab_view: :list,
        grant_resource_id: nil,
        grant_resource_form: nil,
        grant_resource_search: "",
        available_resources: [],
        providers: [],
        timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
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
        resource_access_actions_open_id: nil,
        confirm_remove_resource_access_id: nil,
        panel_members: [],
        panel_members_total: 0,
        panel_member_pages: 1,
        member_page: 1,
        members_to_add: [],
        members_to_remove: [],
        member_search_results: nil,
        last_member_search: "",
        show_member_filter: ""
      )
      |> assign_live_table("groups",
        query_module: Database,
        sortable_fields: [
          {:groups, :name},
          {:member_counts, :count}
        ],
        callback: &handle_groups_update!/2
      )

    {:ok, socket}
  end

  # Add Group Panel
  def handle_params(params, uri, %{assigns: %{live_action: :add}} = socket) do
    changeset = changeset(%Portal.Group{}, %{})
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(socket,
       selected_group: nil,
       panel_view: :new_form,
       confirm_delete: false,
       form: to_form(changeset),
       members_to_add: [],
       member_search_results: nil,
       last_member_search: ""
     )}
  end

  # Edit Group Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    group = Database.get_group_with_actors!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    if editable_group?(group) do
      changeset = changeset(group, %{})

      {:noreply,
       assign(socket,
         selected_group: group,
         panel_view: :edit_form,
         confirm_delete: false,
         form: to_form(changeset),
         members_to_add: [],
         members_to_remove: [],
         member_search_results: nil,
         last_member_search: ""
       )}
    else
      {:noreply,
       socket
       |> put_flash(:error, "This group cannot be edited")
       |> push_patch(to: ~p"/#{socket.assigns.account}/groups/#{id}")}
    end
  end

  # Show Group Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    group = Database.get_group_with_actors!(id, socket.assigns.subject)
    resources = Database.list_resources_for_group(group, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    socket =
      socket
      |> assign(
        selected_group: group,
        panel_view: :list,
        confirm_delete: false,
        group_panel_tab: String.to_existing_atom(Map.get(params, "tab", "members")),
        group_resources: resources,
        resources_tab_view: :list,
        grant_resource_id: nil,
        grant_resource_form: nil,
        grant_resource_search: "",
        available_resources: [],
        resource_access_actions_open_id: nil,
        confirm_remove_resource_access_id: nil,
        show_member_filter: "",
        member_page: 1
      )
      |> load_panel_members()

    {:noreply, socket}
  end

  # Default handler
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(socket,
       selected_group: nil,
       panel_view: :list,
       confirm_delete: false,
       form: nil,
       group_resources: [],
       resources_tab_view: :list,
       grant_resource_id: nil,
       grant_resource_form: nil,
       grant_resource_search: "",
       available_resources: [],
       resource_access_actions_open_id: nil,
       confirm_remove_resource_access_id: nil,
       members_to_add: [],
       members_to_remove: [],
       member_search_results: nil,
       last_member_search: "",
       show_member_filter: ""
     )}
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
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/groups")}
  end

  def handle_event("confirm_delete_group", _params, socket) do
    {:noreply, assign(socket, confirm_delete: true)}
  end

  def handle_event("cancel_delete_group", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false)}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.panel_view == :edit_form do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/groups/#{socket.assigns.selected_group.id}"
     )}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.panel_view == :new_form do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/groups")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_group) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/groups")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"group" => attrs}, socket) do
    group = socket.assigns.selected_group || %Portal.Group{}
    changeset = changeset(group, attrs)

    # Only search if member_search value has changed
    current_search = Map.get(attrs, "member_search", "")
    last_search = socket.assigns.last_member_search

    {member_search_results, last_member_search} =
      if current_search != last_search do
        {get_search_results(current_search, socket), current_search}
      else
        {socket.assigns.member_search_results, last_search}
      end

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       member_search_results: member_search_results,
       last_member_search: last_member_search
     )}
  end

  def handle_event("focus_search", _params, socket) do
    member_search = get_in(socket.assigns.form.params, ["member_search"]) || ""
    search_results = get_search_results(member_search, socket)
    {:noreply, assign(socket, member_search_results: search_results)}
  end

  def handle_event("add_member", %{"actor_id" => actor_id}, socket) do
    actor = Database.get_actor!(actor_id, socket.assigns.subject)

    {members_to_add, members_to_remove} =
      if Map.has_key?(socket.assigns, :members_to_remove) do
        add_member(actor, socket)
      else
        {uniq_by_id([actor | socket.assigns.members_to_add]), []}
      end

    group = socket.assigns.selected_group || %Portal.Group{}
    updated_params = Map.put(socket.assigns.form.params, "member_search", "")
    changeset = changeset(group, updated_params)

    assigns = [
      members_to_add: members_to_add,
      member_search_results: nil,
      form: to_form(changeset),
      last_member_search: ""
    ]

    assigns =
      if members_to_remove != [],
        do: Keyword.put(assigns, :members_to_remove, members_to_remove),
        else: assigns

    {:noreply, assign(socket, assigns)}
  end

  def handle_event("remove_member", %{"actor_id" => actor_id}, socket) do
    {members_to_add, members_to_remove} = remove_member(actor_id, socket)

    {:noreply,
     assign(socket, members_to_add: members_to_add, members_to_remove: members_to_remove)}
  end

  def handle_event("undo_member_removal", %{"actor_id" => actor_id}, socket) do
    members_to_remove = Enum.reject(socket.assigns.members_to_remove, &(&1.id == actor_id))
    {:noreply, assign(socket, members_to_remove: members_to_remove)}
  end

  def handle_event("blur_search", _params, socket) do
    {:noreply, assign(socket, member_search_results: nil)}
  end

  def handle_event("filter_show_members", %{"filter" => filter}, socket) do
    socket =
      socket
      |> assign(show_member_filter: filter, member_page: 1)
      |> load_panel_members()

    {:noreply, socket}
  end

  def handle_event("switch_group_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/groups/#{socket.assigns.selected_group.id}?tab=#{tab}"
     )}
  end

  def handle_event("open_grant_resource_form", _params, socket) do
    existing_ids = Enum.map(socket.assigns.group_resources, & &1.id)
    available = Database.list_available_resources(existing_ids, socket.assigns.subject)
    providers = Database.list_providers(socket.assigns.subject)

    {:noreply,
     assign(socket,
       resources_tab_view: :grant_form,
       available_resources: available,
       providers: providers,
       grant_resource_id: nil,
       grant_resource_form: to_grant_resource_form(),
       grant_resource_search: "",
       location_search: "",
       location_operator: "is_in",
       location_values: [],
       ip_range_operator: "is_in_cidr",
       ip_range_values: [],
       ip_range_input: "",
       auth_provider_operator: "is_in",
       auth_provider_values: [],
       active_conditions: [],
       conditions_dropdown_open: false
     )}
  end

  def handle_event("close_grant_resource_form", _params, socket) do
    {:noreply,
     assign(socket,
       resources_tab_view: :list,
       available_resources: [],
       providers: [],
       grant_resource_id: nil,
       grant_resource_form: nil,
       grant_resource_search: "",
       location_search: "",
       location_operator: "is_in",
       location_values: [],
       ip_range_operator: "is_in_cidr",
       ip_range_values: [],
       ip_range_input: "",
       auth_provider_operator: "is_in",
       auth_provider_values: [],
       active_conditions: [],
       conditions_dropdown_open: false
     )}
  end

  def handle_event("search_grant_resources", %{"value" => search}, socket) do
    {:noreply, assign(socket, grant_resource_search: search)}
  end

  def handle_event("select_grant_resource", %{"resource_id" => resource_id}, socket) do
    resource = Enum.find(socket.assigns.available_resources, &(&1.id == resource_id))
    allowed = available_conditions(resource)
    active = Enum.filter(socket.assigns.active_conditions, &(&1 in allowed))
    {:noreply, assign(socket, grant_resource_id: resource_id, active_conditions: active)}
  end

  def handle_event("submit_grant_resource", %{"policy" => params}, socket) do
    group = socket.assigns.selected_group

    attrs =
      params
      |> Map.put("group_id", group.id)
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    case Database.insert_policy(attrs, socket.assigns.subject) do
      {:ok, _policy} ->
        resources = Database.list_resources_for_group(group, socket.assigns.subject)

        {:noreply,
         assign(socket,
           group_resources: resources,
           resources_tab_view: :list,
           available_resources: [],
           providers: [],
           grant_resource_id: nil,
           grant_resource_form: nil,
           grant_resource_search: "",
           location_search: "",
           location_operator: "is_in",
           location_values: [],
           ip_range_operator: "is_in_cidr",
           ip_range_values: [],
           ip_range_input: "",
           auth_provider_operator: "is_in",
           auth_provider_values: [],
           active_conditions: [],
           conditions_dropdown_open: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, grant_resource_form: to_form(changeset, as: :policy))}
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

  def handle_event("update_location_search", %{"_location_search" => search}, socket) do
    {:noreply, assign(socket, location_search: search)}
  end

  def handle_event("change_location_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, location_operator: op)}
  end

  def handle_event("toggle_location_value", %{"code" => code}, socket) do
    values = socket.assigns.location_values
    updated = if code in values, do: List.delete(values, code), else: values ++ [code]
    {:noreply, assign(socket, location_values: updated)}
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
    updated = if id in values, do: List.delete(values, id), else: values ++ [id]
    {:noreply, assign(socket, auth_provider_values: updated)}
  end

  def handle_event("toggle_resource_access_actions", %{"resource_id" => id}, socket) do
    current = socket.assigns.resource_access_actions_open_id

    {:noreply,
     assign(socket, resource_access_actions_open_id: if(current == id, do: nil, else: id))}
  end

  def handle_event("close_resource_access_actions", _params, socket) do
    {:noreply, assign(socket, resource_access_actions_open_id: nil)}
  end

  def handle_event("disable_resource_access", %{"resource_id" => resource_id}, socket) do
    case Database.disable_policy_for_resource(
           socket.assigns.selected_group,
           resource_id,
           socket.assigns.subject
         ) do
      {:ok, _} ->
        resources =
          Database.list_resources_for_group(socket.assigns.selected_group, socket.assigns.subject)

        {:noreply,
         assign(socket, group_resources: resources, resource_access_actions_open_id: nil)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("enable_resource_access", %{"resource_id" => resource_id}, socket) do
    case Database.enable_policy_for_resource(
           socket.assigns.selected_group,
           resource_id,
           socket.assigns.subject
         ) do
      {:ok, _} ->
        resources =
          Database.list_resources_for_group(socket.assigns.selected_group, socket.assigns.subject)

        {:noreply,
         assign(socket, group_resources: resources, resource_access_actions_open_id: nil)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_remove_resource_access", %{"resource_id" => resource_id}, socket) do
    {:noreply,
     assign(socket,
       confirm_remove_resource_access_id: resource_id,
       resource_access_actions_open_id: nil
     )}
  end

  def handle_event("cancel_remove_resource_access", _params, socket) do
    {:noreply, assign(socket, confirm_remove_resource_access_id: nil)}
  end

  def handle_event("remove_resource_access", %{"resource_id" => resource_id}, socket) do
    case Database.delete_policy_for_resource(
           socket.assigns.selected_group,
           resource_id,
           socket.assigns.subject
         ) do
      {:ok, _} ->
        resources =
          Database.list_resources_for_group(socket.assigns.selected_group, socket.assigns.subject)

        {:noreply,
         assign(socket,
           group_resources: resources,
           confirm_remove_resource_access_id: nil
         )}

      {:error, _} ->
        {:noreply, assign(socket, confirm_remove_resource_access_id: nil)}
    end
  end

  def handle_event("prev_member_page", _params, socket) do
    socket =
      socket
      |> assign(member_page: max(1, socket.assigns.member_page - 1))
      |> load_panel_members()

    {:noreply, socket}
  end

  def handle_event("next_member_page", _params, socket) do
    socket =
      socket
      |> assign(
        member_page: min(socket.assigns.panel_member_pages, socket.assigns.member_page + 1)
      )
      |> load_panel_members()

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    group = Database.get_group!(id, socket.assigns.subject)

    if deletable_group?(group) do
      case Database.delete(group, socket.assigns.subject) do
        {:ok, _group} ->
          socket =
            socket
            |> put_flash(:success, "Group deleted successfully")
            |> reload_live_table!("groups")
            |> push_patch(to: ~p"/#{socket.assigns.account}/groups")

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to delete group")}
      end
    else
      {:noreply, put_flash(socket, :error, "This group cannot be deleted")}
    end
  end

  def handle_event("create", %{"group" => attrs}, socket) do
    attrs = build_attrs_with_memberships_for_add(attrs, socket)
    group = %Portal.Group{account_id: socket.assigns.subject.account.id}
    changeset = changeset(group, attrs)

    case Database.create(changeset, socket.assigns.subject) do
      {:ok, group} ->
        socket =
          socket
          |> put_flash(:success, "Group created successfully")
          |> reload_live_table!("groups")
          |> push_patch(to: ~p"/#{socket.assigns.account}/groups/#{group.id}")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("save", %{"group" => attrs}, socket) do
    if editable_group?(socket.assigns.selected_group) do
      attrs = build_attrs_with_memberships(attrs, socket)
      changeset = changeset(socket.assigns.selected_group, attrs)

      case Database.update(changeset, socket.assigns.subject) do
        {:ok, group} ->
          socket =
            socket
            |> put_flash(:success, "Group updated successfully")
            |> reload_live_table!("groups")
            |> push_patch(to: ~p"/#{socket.assigns.account}/groups/#{group.id}")

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "This group cannot be edited")
       |> close_panel()}
    end
  end

  def handle_groups_update!(socket, list_opts) do
    filter = Keyword.get(list_opts, :filter, [])

    with {:ok, groups, metadata} <- Database.list_groups(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         groups: groups,
         groups_metadata: metadata,
         groups_with_policies_count:
           Database.count_groups_with_policies(socket.assigns.subject, filter)
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="remix-team-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Groups</:title>
        <:description>
          Collections of users.
        </:description>
        <:action>
          <.docs_action path="/deploy/groups" />
          <.button
            style="primary"
            icon="remix-add-line"
            patch={~p"/#{@account}/groups/add"}
          >
            New Group
          </.button>
        </:action>
        <:filters>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {@groups_metadata.count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            With policies {@groups_with_policies_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            No policies {@groups_metadata.count - @groups_with_policies_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="groups"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          row_click={fn g -> ~p"/#{@account}/groups/#{g.id}?#{@query_params}" end}
          row_selected={fn g -> not is_nil(@selected_group) and g.id == @selected_group.id end}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={group} field={{:groups, :name}} label="Name" class="w-full">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4" />
              </div>
              <div class="min-w-0">
                <div class="flex items-center gap-1.5 font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
                  <span class="truncate">{group.name}</span>
                  <span
                    :if={group.entity_type == :org_unit}
                    class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)] shrink-0"
                    title="Organizational Unit"
                  >
                    OU
                  </span>
                </div>
                <div class="text-xs text-[var(--text-tertiary)] truncate">
                  {directory_display_name(group)}
                </div>
              </div>
            </div>
          </:col>
          <:col :let={group} field={{:member_counts, :count}} label="Members" class="w-40">
            <div class="text-sm text-[var(--text-primary)] tabular-nums">
              <span class="font-medium">{group.member_count}</span>
              <span class="text-xs text-[var(--text-tertiary)]">users</span>
            </div>
          </:col>
          <:col :let={group} label="Resources" class="w-54">
            <span class={[
              "inline-flex items-center justify-center w-6 h-6 rounded text-xs font-semibold tabular-nums",
              if((group.policy_count || 0) > 0,
                do: "bg-[var(--brand-muted)] text-[var(--brand)]",
                else: "bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)]"
              )
            ]}>
              {group.policy_count || 0}
            </span>
          </:col>
          <:action :let={_group}></:action>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <svg
                  class="w-4 h-4 text-[var(--text-tertiary)]"
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                >
                  <circle cx="6" cy="5" r="2.5" />
                  <circle cx="11" cy="5" r="2" />
                  <path d="M1 13c0-2.5 2-4 5-4s5 1.5 5 4" />
                  <path d="M11 7c1.5 0 3 1 3 3" />
                </svg>
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No groups yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  No groups have been created yet.
                </p>
              </div>
              <.link
                patch={~p"/#{@account}/groups/add"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-add-line" class="w-3 h-3" /> Add a Group
              </.link>
            </div>
          </:empty>
        </.live_table>
      </div>
      <.group_panel
        account={@account}
        group={@selected_group}
        panel_view={@panel_view}
        form={@form}
        group_panel_tab={@group_panel_tab}
        group_resources={@group_resources}
        resources_tab_view={@resources_tab_view}
        grant_resource_id={@grant_resource_id}
        grant_resource_form={@grant_resource_form}
        grant_resource_search={@grant_resource_search}
        available_resources={@available_resources}
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
        active_conditions={@active_conditions}
        conditions_dropdown_open={@conditions_dropdown_open}
        resource_access_actions_open_id={@resource_access_actions_open_id}
        confirm_remove_resource_access_id={@confirm_remove_resource_access_id}
        panel_members={@panel_members}
        panel_members_total={@panel_members_total}
        panel_member_pages={@panel_member_pages}
        member_page={@member_page}
        members_to_add={@members_to_add}
        members_to_remove={@members_to_remove}
        member_search_results={@member_search_results}
        show_member_filter={@show_member_filter}
        confirm_delete={@confirm_delete}
        query_params={@query_params}
        flash={@flash}
      />
    </div>
    """
  end

  defp actor_type_badge(assigns) do
    assigns = assign_new(assigns, :class, fn -> "w-7 h-7" end)

    ~H"""
    <div class={[
      "inline-flex items-center justify-center rounded-full shrink-0",
      @class,
      actor_type_icon_bg_color(@actor.type)
    ]}>
      <%= case @actor.type do %>
        <% :service_account -> %>
          <.icon name="remix-server-line" class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"} />
        <% :account_admin_user -> %>
          <.icon
            name="remix-shield-check-line"
            class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"}
          />
        <% _ -> %>
          <.icon name="remix-user-line" class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"} />
      <% end %>
    </div>
    """
  end

  defp actor_type_icon_bg_color(:service_account), do: "bg-blue-100"
  defp actor_type_icon_bg_color(:account_admin_user), do: "bg-purple-100"
  defp actor_type_icon_bg_color(_), do: "bg-neutral-100"

  defp actor_type_icon_text_color(:service_account), do: "text-blue-800"
  defp actor_type_icon_text_color(:account_admin_user), do: "text-purple-800"
  defp actor_type_icon_text_color(_), do: "text-neutral-800"

  defp member_search_input(assigns) do
    assigns = assign_new(assigns, :placeholder, fn -> "Search to add members..." end)

    ~H"""
    <div
      class="p-3 bg-[var(--surface-raised)] border-b border-[var(--border)] relative"
      phx-click-away="blur_search"
    >
      <div class="relative">
        <.icon
          name="remix-search-line"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-[var(--text-tertiary)] pointer-events-none"
        />
        <input
          type="text"
          name={@form[:member_search].name}
          value={@form[:member_search].value}
          placeholder={@placeholder}
          phx-debounce="300"
          phx-focus="focus_search"
          autocomplete="off"
          data-1p-ignore
          class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-[var(--border)] bg-[var(--surface)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors"
        />
      </div>

      <div
        :if={@member_search_results != nil}
        class="absolute z-10 left-3 right-3 mt-1 bg-[var(--surface-overlay)] border border-[var(--border)] rounded-lg shadow-lg max-h-48 overflow-y-auto"
      >
        <button
          :for={actor <- @member_search_results}
          type="button"
          phx-click="add_member"
          phx-value-actor_id={actor.id}
          class="w-full text-left px-3 py-2 hover:bg-[var(--surface-raised)] border-b border-[var(--border)] last:border-b-0 transition-colors"
        >
          <div class="space-y-0.5">
            <div class="flex items-center gap-2">
              <.actor_type_badge actor={actor} />
              <div class="text-xs font-medium text-[var(--text-primary)]">{actor.name}</div>
            </div>
            <div :if={actor.email} class="text-xs text-[var(--text-tertiary)] pl-9">
              {actor.email}
            </div>
          </div>
        </button>
        <div
          :if={@member_search_results == []}
          class="px-3 py-4 text-center text-xs text-[var(--text-tertiary)]"
        >
          No members found
        </div>
      </div>
    </div>
    """
  end

  defp member_list(assigns) do
    assigns =
      assigns
      |> assign_new(:item_class, fn -> "px-3 py-2.5 flex items-center justify-between group" end)
      |> assign_new(:list_class, fn -> "divide-y divide-[var(--border)] h-64 overflow-y-auto" end)
      |> assign_new(:empty_class, fn -> "flex items-center justify-center h-64" end)
      |> assign(:has_actions, Map.get(assigns, :actions) != nil)

    ~H"""
    <ul :if={@members != []} class={@list_class}>
      <li :for={actor <- @members} class={@item_class}>
        <div class={["flex items-center gap-3", @has_actions && "flex-1 min-w-0"]}>
          <%= if Map.get(assigns, :badge) do %>
            {render_slot(@badge, actor)}
          <% end %>
          <div class={@has_actions && "flex-1 min-w-0"}>
            <p class={["text-xs font-medium text-[var(--text-primary)]", @has_actions && "truncate"]}>
              {actor.name}
            </p>
            <p
              :if={actor.email}
              class={["text-xs text-[var(--text-tertiary)]", @has_actions && "truncate"]}
            >
              {actor.email}
            </p>
          </div>
        </div>
        <%= if @has_actions do %>
          {render_slot(@actions, actor)}
        <% end %>
      </li>
    </ul>

    <div :if={@members == []} class={@empty_class}>
      <p class="text-xs text-[var(--text-tertiary)]">
        {render_slot(@empty_message)}
      </p>
    </div>
    """
  end

  defp group_panel(assigns) do
    ~H"""
    <div
      id="group-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@group || @panel_view == :new_form, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <%!-- Form view (new or edit) --%>
      <div :if={@panel_view in [:new_form, :edit_form]} class="flex flex-col h-full overflow-hidden">
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-center justify-between gap-3">
            <div class="flex items-center gap-2 min-w-0">
              <.link
                :if={@panel_view == :edit_form && @group}
                patch={~p"/#{@account}/groups/#{@group.id}"}
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors shrink-0"
                title="Back to group"
              >
                <.icon name="remix-arrow-left-line" class="w-4 h-4" />
              </.link>
              <h2 class="text-sm font-semibold text-[var(--text-primary)] truncate">
                {if @panel_view == :new_form, do: "New Group", else: "Edit #{@group && @group.name}"}
              </h2>
            </div>
            <button
              phx-click="close_panel"
              class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors shrink-0"
              title="Close (Esc)"
            >
              <.icon name="remix-close-line" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <.form
          id="group-form"
          for={@form}
          phx-change="validate"
          phx-submit={if @panel_view == :new_form, do: "create", else: "save"}
          class="flex flex-col flex-1 min-h-0 overflow-hidden"
        >
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
            <.flash id="group-success-inline" kind={:success_inline} style="inline" flash={@flash} />
            <.input
              field={@form[:name]}
              label="Group Name"
              placeholder="Enter group name"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
            <div>
              <% all_members =
                if @panel_view == :edit_form && @group do
                  get_all_members_for_display(@group, @members_to_add, @members_to_remove)
                else
                  @members_to_add
                end %>
              <h3 class="text-sm font-medium text-[var(--text-secondary)] mb-2">
                {if @panel_view == :edit_form,
                  do: "Members (#{get_member_count(all_members, @members_to_remove)})",
                  else: "Members (#{length(@members_to_add)})"}
              </h3>
              <div class="border border-[var(--border)] rounded-md overflow-hidden">
                <.member_search_input form={@form} member_search_results={@member_search_results} />
                <.member_list members={all_members}>
                  <:badge :let={actor}>
                    <.actor_type_badge actor={actor} />
                  </:badge>
                  <:actions :let={actor}>
                    <% is_current = current_member?(actor, @group)
                    is_to_add = Enum.any?(@members_to_add, &(&1.id == actor.id))
                    is_to_remove = Enum.any?(@members_to_remove, &(&1.id == actor.id)) %>
                    <div class="ml-4 flex items-center gap-2">
                      <span
                        :if={is_current and not is_to_remove}
                        class="text-xs text-[var(--text-tertiary)]"
                      >
                        Current
                      </span>
                      <span :if={is_to_add} class="text-xs text-green-600 font-medium">
                        To Add
                      </span>
                      <span :if={is_to_remove} class="text-xs text-red-600 font-medium">
                        To Remove
                      </span>
                      <button
                        :if={is_to_remove}
                        type="button"
                        phx-click="undo_member_removal"
                        phx-value-actor_id={actor.id}
                        class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
                      >
                        <.icon name="remix-arrow-go-back-line" class="w-5 h-5" />
                      </button>
                      <button
                        :if={not is_to_remove}
                        type="button"
                        phx-click="remove_member"
                        phx-value-actor_id={actor.id}
                        class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--status-error)] transition-colors"
                      >
                        <.icon name="remix-user-minus-line" class="w-5 h-5" />
                      </button>
                    </div>
                  </:actions>
                  <:empty_message>
                    No members added yet.
                  </:empty_message>
                </.member_list>
              </div>
            </div>
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
            <.link
              patch={
                if @panel_view == :edit_form && @group,
                  do: ~p"/#{@account}/groups/#{@group.id}",
                  else: ~p"/#{@account}/groups"
              }
              class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </.link>
            <button
              type="submit"
              disabled={
                if @panel_view == :new_form,
                  do: not @form.source.valid?,
                  else: edit_form_unchanged?(@form, @members_to_add, @members_to_remove)
              }
              class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {if @panel_view == :new_form, do: "Create Group", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>

      <%!-- Show (list) view --%>
      <div
        :if={@group && @panel_view == :list}
        class="flex flex-col h-full overflow-hidden"
      >
        <div class="shrink-0 px-5 py-4 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-start justify-between gap-3">
            <div class="flex items-center gap-3 min-w-0">
              <div class="flex items-center justify-center w-8 h-8 shrink-0">
                <.provider_icon type={provider_type_from_group(@group)} class="w-6 h-6" />
              </div>
              <div class="min-w-0">
                <h2 class="text-sm font-semibold text-[var(--text-primary)] truncate">
                  {@group.name}
                </h2>
                <div class="flex items-center gap-1.5 mt-0.5">
                  <span
                    :if={@group.entity_type == :org_unit}
                    class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)]"
                  >
                    OU
                  </span>
                  <span class="text-xs text-[var(--text-tertiary)]">
                    {directory_display_name(@group)}
                  </span>
                </div>
              </div>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <.link
                :if={editable_group?(@group) and not @confirm_delete}
                patch={~p"/#{@account}/groups/#{@group.id}/edit"}
                class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-pencil-line" class="w-3.5 h-3.5" /> Edit
              </.link>
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

        <%!-- Body: two columns --%>
        <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
          <%!-- Left: tabbed content --%>
          <div class="flex-1 flex flex-col overflow-hidden">
            <%!-- Tab bar --%>
            <div class="flex items-end gap-0 px-5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
              <button
                phx-click="switch_group_tab"
                phx-value-tab="members"
                class={[
                  "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
                  if(@group_panel_tab == :members,
                    do: "border-[var(--brand)] text-[var(--brand)]",
                    else:
                      "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
                  )
                ]}
              >
                Members
                <span class={[
                  "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
                  if(@group_panel_tab == :members,
                    do: "bg-[var(--brand-muted)] text-[var(--brand)]",
                    else: "bg-[var(--surface-raised)] text-[var(--text-tertiary)]"
                  )
                ]}>
                  {@panel_members_total}
                </span>
              </button>
              <button
                phx-click="switch_group_tab"
                phx-value-tab="resources"
                class={[
                  "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
                  if(@group_panel_tab == :resources,
                    do: "border-[var(--brand)] text-[var(--brand)]",
                    else:
                      "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)]"
                  )
                ]}
              >
                Resources
                <span class={[
                  "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
                  if(@group_panel_tab == :resources,
                    do: "bg-[var(--brand-muted)] text-[var(--brand)]",
                    else: "bg-[var(--surface-raised)] text-[var(--text-tertiary)]"
                  )
                ]}>
                  {length(@group_resources)}
                </span>
              </button>
              <%!-- Grant access button (resources tab only) --%>
              <div
                :if={@group_panel_tab == :resources && @resources_tab_view == :list}
                class="ml-auto pb-2 flex items-center"
              >
                <button
                  type="button"
                  phx-click="open_grant_resource_form"
                  class="flex items-center gap-1 px-2 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="remix-add-line" class="w-3 h-3" /> Grant access
                </button>
              </div>
              <%!-- Filter input (members tab only) --%>
              <div :if={@group_panel_tab == :members} class="ml-auto pb-2 flex items-center">
                <form phx-change="filter_show_members">
                  <div class="relative">
                    <.icon
                      name="remix-search-line"
                      class="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-[var(--text-tertiary)]"
                    />
                    <input
                      type="text"
                      value={@show_member_filter}
                      placeholder="Filter…"
                      phx-debounce="300"
                      name="filter"
                      autocomplete="off"
                      data-1p-ignore
                      class="pl-6 pr-2 py-1 text-xs rounded border bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors w-32"
                    />
                  </div>
                </form>
              </div>
            </div>
            <%!-- Members tab --%>
            <div :if={@group_panel_tab == :members} class="flex-1 flex flex-col overflow-hidden">
              <% total_pages = @panel_member_pages %>
              <.flash
                id="group-success-inline-show"
                kind={:success_inline}
                style="inline"
                flash={@flash}
              />
              <%!-- Scrollable list --%>
              <div class="flex-1 overflow-y-auto">
                <div
                  :if={@panel_members == [] && @panel_members_total == 0}
                  class="flex items-center justify-center py-16"
                >
                  <p class="text-sm text-[var(--text-tertiary)]">
                    <%= if has_content?(@show_member_filter) do %>
                      No members match your filter.
                    <% else %>
                      No members in this group.
                    <% end %>
                  </p>
                </div>
                <ul :if={@panel_members != []} class="divide-y divide-[var(--border)]">
                  <li :for={actor <- @panel_members} class="transition-colors">
                    <div class="flex items-center gap-3 px-5 py-3 hover:bg-[var(--surface-raised)]">
                      <.actor_type_badge actor={actor} />
                      <div class="flex-1 min-w-0">
                        <p class="text-sm font-medium text-[var(--text-primary)] truncate">
                          {actor.name}
                        </p>
                        <p :if={actor.email} class="text-xs text-[var(--text-tertiary)] truncate">
                          {actor.email}
                        </p>
                      </div>
                    </div>
                  </li>
                </ul>
              </div>
              <%!-- Pagination footer (always at bottom) --%>
              <div
                :if={total_pages > 1}
                class="shrink-0 flex items-center justify-between px-5 py-2.5 border-t border-[var(--border)] bg-[var(--surface-raised)]"
              >
                <span class="text-xs text-[var(--text-tertiary)]">
                  Page {@member_page} of {total_pages}
                  <span class="text-[var(--text-muted)]">({@panel_members_total} members)</span>
                </span>
                <div class="flex items-center gap-1">
                  <button
                    type="button"
                    phx-click="prev_member_page"
                    disabled={@member_page <= 1}
                    class="flex items-center justify-center w-7 h-7 rounded border border-[var(--border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                  >
                    <.icon name="remix-arrow-left-s-line" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    type="button"
                    phx-click="next_member_page"
                    disabled={@member_page >= total_pages}
                    class="flex items-center justify-center w-7 h-7 rounded border border-[var(--border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                  >
                    <.icon name="remix-arrow-right-s-line" class="w-3.5 h-3.5" />
                  </button>
                </div>
              </div>
            </div>
            <%!-- Resources tab --%>
            <div :if={@group_panel_tab == :resources} class="flex-1 flex flex-col overflow-hidden">
              <%!-- Grant resource form --%>
              <%= if @resources_tab_view == :grant_form do %>
                <div class="flex items-center justify-between px-5 py-2.5 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="close_grant_resource_form"
                      class="flex items-center justify-center w-5 h-5 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface)] transition-colors"
                      title="Back to resource list"
                    >
                      <.icon name="remix-arrow-left-s-line" class="w-3.5 h-3.5" />
                    </button>
                    <span class="text-xs font-semibold text-[var(--text-primary)]">Grant access</span>
                  </div>
                  <span class="text-xs text-[var(--text-tertiary)]">
                    {length(@available_resources)} available
                  </span>
                </div>
                <.form
                  for={@grant_resource_form}
                  phx-submit="submit_grant_resource"
                  id="grant-resource-form"
                  class="flex-1 flex flex-col overflow-hidden"
                >
                  <input type="hidden" name="policy[resource_id]" value={@grant_resource_id} />
                  <div class="flex-1 overflow-y-auto">
                    <div class="px-5 py-4 space-y-5">
                      <div>
                        <label class="block text-xs font-medium text-[var(--text-secondary)] mb-2">
                          Resource <span class="text-[var(--status-error)]">*</span>
                        </label>
                        <div class="relative mb-2">
                          <.icon
                            name="remix-search-line"
                            class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-[var(--text-tertiary)] pointer-events-none"
                          />
                          <input
                            type="text"
                            placeholder="Filter resources…"
                            value={@grant_resource_search}
                            phx-keyup="search_grant_resources"
                            phx-debounce="200"
                            autocomplete="off"
                            data-1p-ignore
                            class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-[var(--border)] bg-[var(--surface-raised)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors"
                          />
                        </div>
                        <% filtered_resources =
                          if @grant_resource_search == "" do
                            Enum.take(@available_resources, 5)
                          else
                            @available_resources
                            |> Enum.filter(fn r ->
                              String.contains?(
                                String.downcase(r.name),
                                String.downcase(@grant_resource_search)
                              ) or
                                String.contains?(
                                  String.downcase(r.address || ""),
                                  String.downcase(@grant_resource_search)
                                )
                            end)
                            |> Enum.take(5)
                          end %>
                        <ul class="space-y-1">
                          <li :for={resource <- filtered_resources}>
                            <button
                              type="button"
                              phx-click="select_grant_resource"
                              phx-value-resource_id={resource.id}
                              class={[
                                "flex items-center gap-3 px-3 py-2.5 w-full rounded-lg border cursor-pointer transition-colors",
                                if @grant_resource_id == resource.id do
                                  "border-[var(--brand)] bg-[var(--brand-muted)]"
                                else
                                  "border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)]"
                                end
                              ]}
                            >
                              <div class="flex-1 min-w-0 text-left">
                                <p class={[
                                  "text-sm font-medium truncate transition-colors",
                                  if(@grant_resource_id == resource.id,
                                    do: "text-[var(--brand)]",
                                    else: "text-[var(--text-primary)]"
                                  )
                                ]}>
                                  {resource.name}
                                </p>
                                <p class="text-xs text-[var(--text-tertiary)] font-mono truncate">
                                  {resource.address}
                                </p>
                              </div>
                              <.icon
                                :if={@grant_resource_id == resource.id}
                                name="remix-check-line"
                                class="w-4 h-4 text-[var(--brand)] shrink-0"
                              />
                            </button>
                          </li>
                        </ul>
                        <div
                          :if={@available_resources == []}
                          class="flex items-center justify-center h-24 text-sm text-[var(--text-tertiary)]"
                        >
                          All resources already have access.
                        </div>
                        <div
                          :if={@available_resources != [] && filtered_resources == []}
                          class="flex items-center justify-center h-16 text-sm text-[var(--text-tertiary)]"
                        >
                          No resources match your search.
                        </div>
                        <p
                          :if={length(@available_resources) > 5 && filtered_resources != []}
                          class="mt-2 text-center text-[10px] text-[var(--text-muted)]"
                        >
                          Showing {length(filtered_resources)} of {length(@available_resources)} — type to narrow results
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
                            :if={
                              available_conditions(
                                Enum.find(@available_resources, &(&1.id == @grant_resource_id))
                              ) --
                                @active_conditions != []
                            }
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
                              <div
                                class="fixed inset-0 z-10"
                                phx-click="toggle_conditions_dropdown"
                              >
                              </div>
                              <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-[var(--border-strong)] bg-[var(--surface-overlay)] shadow-lg py-1 overflow-hidden">
                                <button
                                  :for={
                                    type <-
                                      available_conditions(
                                        Enum.find(
                                          @available_resources,
                                          &(&1.id == @grant_resource_id)
                                        )
                                      ) -- @active_conditions
                                  }
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
                    :if={@grant_resource_form && @grant_resource_form.errors != []}
                    class="px-5 py-2 text-xs text-[var(--status-error)]"
                  >
                    <p :for={{_field, {msg, _}} <- @grant_resource_form.errors}>{msg}</p>
                  </div>
                  <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
                    <button
                      type="button"
                      phx-click="close_grant_resource_form"
                      class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      disabled={is_nil(@grant_resource_id)}
                      class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      Grant access
                    </button>
                  </div>
                </.form>
              <% else %>
                <div class="flex-1 overflow-y-auto">
                  <div
                    :if={@group_resources == []}
                    class="flex flex-col items-center justify-center h-full py-12 text-center"
                  >
                    <p class="text-sm font-medium text-[var(--text-secondary)]">No resource access</p>
                    <p class="text-xs text-[var(--text-tertiary)] mt-1">
                      Assign a policy to grant this group access.
                    </p>
                  </div>
                  <ul :if={@group_resources != []}>
                    <li
                      :for={resource <- @group_resources}
                      class={[
                        "border-b border-[var(--border)] transition-colors",
                        @resource_access_actions_open_id == resource.id && "relative z-20"
                      ]}
                    >
                      <%!-- Confirm remove inline --%>
                      <div
                        :if={@confirm_remove_resource_access_id == resource.id}
                        class="flex items-center justify-between gap-2 px-4 py-2.5 bg-[var(--surface-raised)]"
                      >
                        <span class="text-xs text-[var(--text-secondary)] truncate">
                          Remove access to <span class="font-medium text-[var(--text-primary)]">{resource.name}</span>?
                          <span class="block text-[var(--text-tertiary)]">
                            All group members will immediately lose access.
                          </span>
                        </span>
                        <div class="flex items-center gap-1.5 shrink-0">
                          <button
                            type="button"
                            phx-click="cancel_remove_resource_access"
                            class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                          >
                            Cancel
                          </button>
                          <button
                            type="button"
                            phx-click="remove_resource_access"
                            phx-value-resource_id={resource.id}
                            class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/30 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors"
                          >
                            Remove
                          </button>
                        </div>
                      </div>
                      <%!-- Normal row --%>
                      <div
                        :if={@confirm_remove_resource_access_id != resource.id}
                        class={[
                          "flex items-center gap-1 pr-4 hover:bg-[var(--surface-raised)] group/item",
                          not is_nil(resource.policy_disabled_at) && "opacity-50 hover:opacity-75"
                        ]}
                      >
                        <.link
                          navigate={~p"/#{@account}/resources/#{resource.id}"}
                          class="flex items-center gap-3 px-5 py-3 flex-1 min-w-0"
                        >
                          <div class="w-14 shrink-0 flex">
                            <span class={type_badge_class(resource.type)}>
                              {resource.type}
                            </span>
                          </div>
                          <div class="flex-1 min-w-0">
                            <div class="flex items-center gap-2">
                              <p class="text-sm font-medium text-[var(--text-primary)] group-hover/item:text-[var(--brand)] transition-colors truncate">
                                {resource.name}
                              </p>
                              <span
                                :if={not is_nil(resource.policy_disabled_at)}
                                class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-[var(--status-neutral-bg)] text-[var(--text-tertiary)] shrink-0"
                              >
                                disabled
                              </span>
                            </div>
                            <span class="text-xs text-[var(--text-tertiary)] font-mono truncate block">
                              {resource.address}
                            </span>
                          </div>
                        </.link>
                        <div class="relative shrink-0">
                          <button
                            type="button"
                            phx-click="toggle_resource_access_actions"
                            phx-value-resource_id={resource.id}
                            class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface)] transition-colors"
                            title="More actions"
                          >
                            <.icon name="remix-more-2-line" class="w-3.5 h-3.5" />
                          </button>
                          <div
                            :if={@resource_access_actions_open_id == resource.id}
                            phx-click-away="close_resource_access_actions"
                            class="absolute right-0 top-full mt-1 w-44 rounded-md border border-[var(--border)] bg-[var(--surface-overlay)] shadow-lg z-10 py-1"
                          >
                            <button
                              :if={is_nil(resource.policy_disabled_at)}
                              type="button"
                              phx-click="disable_resource_access"
                              phx-value-resource_id={resource.id}
                              class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                            >
                              <.icon name="remix-pause-line" class="w-3.5 h-3.5 shrink-0" /> Disable
                            </button>
                            <button
                              :if={not is_nil(resource.policy_disabled_at)}
                              type="button"
                              phx-click="enable_resource_access"
                              phx-value-resource_id={resource.id}
                              class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                            >
                              <.icon name="remix-play-line" class="w-3.5 h-3.5 shrink-0" /> Enable
                            </button>
                            <button
                              type="button"
                              phx-click="confirm_remove_resource_access"
                              phx-value-resource_id={resource.id}
                              class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-[var(--status-error)] hover:bg-[var(--surface-raised)] transition-colors"
                            >
                              <.icon name="remix-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Remove access
                            </button>
                          </div>
                        </div>
                      </div>
                    </li>
                  </ul>
                </div>
              <% end %>
            </div>
          </div>
          <%!-- Right: details sidebar --%>
          <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
            <section>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                Details
              </h3>
              <dl class="space-y-2.5">
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">ID</dt>
                  <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                    {@group.id}
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Name</dt>
                  <dd class="text-xs text-[var(--text-secondary)] truncate" title={@group.name}>
                    {@group.name}
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Directory</dt>
                  <dd class="text-xs text-[var(--text-secondary)]">
                    {directory_display_name(@group)}
                  </dd>
                </div>
                <div :if={@group.entity_type == :org_unit}>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Type</dt>
                  <dd class="text-xs text-[var(--text-secondary)]">Org Unit</dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Created</dt>
                  <dd class="text-xs text-[var(--text-secondary)] mt-0.5">
                    <.relative_datetime datetime={@group.inserted_at} />
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Updated</dt>
                  <dd class="text-xs text-[var(--text-secondary)] mt-0.5">
                    <.relative_datetime datetime={@group.updated_at} />
                  </dd>
                </div>
                <div :if={@group.last_synced_at}>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Last Synced</dt>
                  <dd class="text-xs text-[var(--text-secondary)] mt-0.5">
                    <.relative_datetime datetime={@group.last_synced_at} />
                  </dd>
                </div>
                <div :if={@group.idp_id && get_idp_id(@group.idp_id)}>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">IDP ID</dt>
                  <dd
                    class="font-mono text-[11px] text-[var(--text-secondary)] break-all mt-0.5"
                    title={get_idp_id(@group.idp_id)}
                  >
                    {get_idp_id(@group.idp_id)}
                  </dd>
                </div>
              </dl>
            </section>
            <div :if={deletable_group?(@group)} class="border-t border-[var(--border)]"></div>
            <section :if={deletable_group?(@group)}>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
                Danger Zone
              </h3>
              <button
                :if={not @confirm_delete}
                type="button"
                phx-click="confirm_delete_group"
                class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
              >
                Delete group
              </button>
              <div
                :if={@confirm_delete}
                class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
              >
                <p class="text-xs font-medium text-[var(--status-error)] mb-1">
                  Delete this group?
                </p>
                <p class="text-xs text-[var(--status-error)]/70 mb-3">
                  All associated policies will also be deleted and clients will immediately lose access.
                </p>
                <div class="flex items-center gap-1.5">
                  <button
                    type="button"
                    phx-click="cancel_delete_group"
                    class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={@group.id}
                    class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp editable_group?(%{type: :managed, name: "Everyone"}), do: false
  defp editable_group?(%{idp_id: nil}), do: true
  defp editable_group?(_group), do: false

  @spec load_panel_members(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_panel_members(socket) do
    group = socket.assigns.selected_group
    subject = socket.assigns.subject
    page = socket.assigns.member_page
    filter = socket.assigns.show_member_filter

    {members, total} =
      Database.list_group_members(group, subject, page, @member_page_size, filter)

    assign(socket,
      panel_members: members,
      panel_members_total: total,
      panel_member_pages: max(1, ceil(total / @member_page_size))
    )
  end

  defp deletable_group?(%{name: "Everyone"}), do: false
  defp deletable_group?(_group), do: true

  defp directory_display_name(%{directory_name: name}) when not is_nil(name), do: name
  defp directory_display_name(%{idp_id: idp_id}) when not is_nil(idp_id), do: "Unknown"
  defp directory_display_name(_), do: "Firezone"

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
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  defp type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--surface-raised)] text-[var(--text-secondary)]"

  defp get_idp_id(nil), do: nil

  defp get_idp_id(idp_id) do
    case String.split(idp_id, ":", parts: 2) do
      [_provider, actual_id] -> actual_id
      _ -> idp_id
    end
  end

  # Utility helpers
  defp has_content?(str), do: String.trim(str) != ""

  defp uniq_by_id(list), do: Enum.uniq_by(list, & &1.id)

  defp edit_form_unchanged?(form, members_to_add, members_to_remove) do
    not form.source.valid? or
      (Enum.empty?(form.source.changes) and members_to_add == [] and members_to_remove == [])
  end

  # Navigation helpers
  defp close_panel(socket) do
    if return_to = handle_return_to(socket) do
      push_navigate(socket, to: return_to)
    else
      push_patch(socket, to: ~p"/#{socket.assigns.account}/groups")
    end
  end

  defp handle_return_to(%{
         assigns: %{query_params: %{"return_to" => return_to}, current_path: current_path}
       })
       when not is_nil(return_to) and not is_nil(current_path) do
    validate_return_to(
      String.split(return_to, "/", parts: 2),
      String.split(current_path, "/", parts: 2)
    )
  end

  defp handle_return_to(_socket), do: nil

  defp validate_return_to([account | _ret_parts] = return_to, [account | _cur_parts]),
    do: Enum.join(return_to, "/")

  defp validate_return_to(_return_to, _current_path), do: nil

  # Member search helpers
  defp get_search_results(search_term, socket) do
    if has_content?(search_term) do
      group = socket.assigns.selected_group || %Portal.Group{actors: []}
      members_to_remove = Map.get(socket.assigns, :members_to_remove, [])
      remove_ids = MapSet.new(members_to_remove, & &1.id)

      # Exclude current members (minus those pending removal) and pending additions
      current_actors = Enum.reject(group.actors, &MapSet.member?(remove_ids, &1.id))
      exclude_actors = uniq_by_id(current_actors ++ socket.assigns.members_to_add)

      Database.search_actors(search_term, socket.assigns.subject, exclude_actors)
    else
      nil
    end
  end

  # Member management helpers
  defp get_all_members_for_display(group, members_to_add, _members_to_remove) do
    uniq_by_id(group.actors ++ members_to_add)
  end

  defp get_member_count(all_members, members_to_remove) do
    length(all_members) - length(members_to_remove)
  end

  defp add_member(actor, socket) do
    members_to_remove = Enum.reject(socket.assigns.members_to_remove, &(&1.id == actor.id))

    members_to_add =
      if current_member?(actor, socket.assigns.selected_group) do
        socket.assigns.members_to_add
      else
        uniq_by_id([actor | socket.assigns.members_to_add])
      end

    {members_to_add, members_to_remove}
  end

  defp remove_member(actor_id, socket) do
    members_to_add = Enum.reject(socket.assigns.members_to_add, &(&1.id == actor_id))

    members_to_remove =
      if actor = find_current_member(actor_id, socket.assigns.selected_group) do
        uniq_by_id([actor | socket.assigns.members_to_remove])
      else
        socket.assigns.members_to_remove
      end

    {members_to_add, members_to_remove}
  end

  defp current_member?(_actor, nil), do: false

  defp current_member?(actor, group) do
    Enum.any?(group.actors, &(&1.id == actor.id))
  end

  defp find_current_member(_actor_id, nil), do: nil

  defp find_current_member(actor_id, group) do
    Enum.find(group.actors, &(&1.id == actor_id))
  end

  defp build_attrs_with_memberships(attrs, socket) do
    group = socket.assigns.selected_group
    final_member_ids = calculate_final_member_ids(socket)

    # Build a lookup from actor_id to the existing membership struct so we can
    # include PK fields (id, account_id) for unchanged memberships. Without these,
    # cast_assoc treats every entry as new and deletes+re-inserts all rows.
    existing_by_actor = Map.new(group.memberships, &{&1.actor_id, &1})

    memberships =
      Enum.map(final_member_ids, fn actor_id ->
        case Map.get(existing_by_actor, actor_id) do
          nil -> %{actor_id: actor_id}
          m -> %{id: m.id, account_id: m.account_id, actor_id: actor_id}
        end
      end)

    Map.put(attrs, "memberships", memberships)
  end

  defp build_attrs_with_memberships_for_add(attrs, socket) do
    member_ids = Enum.map(socket.assigns.members_to_add, & &1.id)
    memberships = Enum.map(member_ids, &%{actor_id: &1})
    Map.put(attrs, "memberships", memberships)
  end

  defp calculate_final_member_ids(socket) do
    current_ids = Enum.map(socket.assigns.selected_group.actors, & &1.id)
    to_add_ids = Enum.map(socket.assigns.members_to_add, & &1.id)
    to_remove_ids = Enum.map(socket.assigns.members_to_remove, & &1.id)

    (current_ids ++ to_add_ids)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in to_remove_ids))
  end

  @spec to_grant_resource_form() :: Phoenix.HTML.Form.t()
  defp to_grant_resource_form do
    %Portal.Policy{}
    |> Ecto.Changeset.change()
    |> to_form(as: :policy)
  end

  # Changesets
  defp changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> cast_assoc(:memberships,
      with: fn membership, attrs ->
        membership
        |> cast(attrs, [:actor_id])
        |> validate_required([:actor_id])
        |> put_change(:account_id, group.account_id)
      end
    )
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.Safe
    alias Portal.Directory
    alias Portal.Repo.Filter

    def all do
      from(groups in Portal.Group, as: :groups)
    end

    # Inlined from Portal.Actors.list_groups
    def list_groups(subject, opts \\ []) do
      # Extract order_by to handle member_count sorting specially
      {order_by, opts} = Keyword.pop(opts, :order_by, [])

      member_counts_query =
        from(m in Portal.Membership,
          group_by: m.group_id,
          select: %{
            group_id: m.group_id,
            count: count(m.actor_id)
          }
        )

      policy_counts_query =
        from(p in Portal.Policy,
          where: is_nil(p.disabled_at),
          group_by: p.group_id,
          select: %{
            group_id: p.group_id,
            count: count(p.id)
          }
        )

      query =
        from(g in Portal.Group, as: :groups)
        |> join(:left, [groups: g], mc in subquery(member_counts_query),
          on: mc.group_id == g.id,
          as: :member_counts
        )
        |> join(:left, [groups: g], pc in subquery(policy_counts_query),
          on: pc.group_id == g.id,
          as: :policy_counts
        )
        |> join(:left, [groups: g], d in Directory,
          on: d.id == g.directory_id and d.account_id == g.account_id,
          as: :directory
        )
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> where(
          [groups: g],
          not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
        )
        |> select_merge([groups: g, member_counts: mc, policy_counts: pc, directory: d], %{
          count: coalesce(mc.count, 0),
          member_count: coalesce(mc.count, 0),
          policy_count: coalesce(pc.count, 0),
          directory_type: d.type
        })
        |> select_merge(
          [google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name: fragment("COALESCE(?, ?, ?)", gd.name, ed.name, od.name)
          }
        )

      # Apply manual ordering with NULLS LAST for count field
      {query, final_order_by} =
        case order_by do
          [{:member_counts, :desc, :count}] ->
            # Apply ordering manually with NULLS LAST, don't pass to Safe.list
            updated_query =
              query
              |> order_by([member_counts: mc], fragment("? DESC NULLS LAST", mc.count))

            {updated_query, []}

          [{:member_counts, :asc, :count}] ->
            # Apply ordering manually with NULLS FIRST, don't pass to Safe.list
            updated_query =
              query
              |> order_by([member_counts: mc], fragment("? ASC NULLS FIRST", mc.count))

            {updated_query, []}

          _ ->
            # Let Safe.list handle the ordering normally
            {query, order_by}
        end

      query
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, Keyword.put(opts, :order_by, final_order_by))
    end

    def count_groups_with_policies(subject, filter \\ []) do
      query =
        from(g in Portal.Group, as: :groups)
        |> join(:inner, [groups: g], p in Portal.Policy,
          on: p.group_id == g.id and is_nil(p.disabled_at),
          as: :policies
        )
        |> where(
          [groups: g],
          not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
        )
        |> select([groups: g], count(g.id, :distinct))

      query =
        case Filter.filter(query, __MODULE__, filter) do
          {:ok, filtered} -> filtered
          _ -> query
        end

      query
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
      |> case do
        {:error, _} -> 0
        nil -> 0
        count -> count
      end
    end

    def count_total_members(subject) do
      member_counts_query =
        from(m in Portal.Membership,
          group_by: m.group_id,
          select: %{group_id: m.group_id, count: count(m.actor_id)}
        )

      from(g in Portal.Group, as: :groups)
      |> join(:left, [groups: g], mc in subquery(member_counts_query),
        on: mc.group_id == g.id,
        as: :member_counts
      )
      |> where(
        [groups: g],
        not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
      )
      |> select([member_counts: mc], sum(coalesce(mc.count, 0)))
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
      |> case do
        {:error, _} -> 0
        nil -> 0
        count -> count
      end
    end

    def cursor_fields do
      [
        {:groups, :asc, :inserted_at},
        {:groups, :asc, :id}
      ]
    end

    def filters do
      [
        %Filter{
          name: :directory_id,
          title: "Directory",
          type: {:string, :select},
          values: &directory_values/1,
          fun: &filter_by_directory/2
        },
        %Filter{
          name: :name,
          title: "Name",
          type: {:string, :websearch},
          fun: &filter_by_name/2
        }
      ]
    end

    # Define a simple struct-like module for directory options
    defmodule DirectoryOption do
      defstruct [:id, :name]
    end

    defp directory_values(subject) do
      directories =
        from(d in Directory,
          where: d.account_id == ^subject.account.id,
          left_join: google in Portal.Google.Directory,
          on: google.id == d.id and d.type == :google,
          left_join: entra in Portal.Entra.Directory,
          on: entra.id == d.id and d.type == :entra,
          left_join: okta in Portal.Okta.Directory,
          on: okta.id == d.id and d.type == :okta,
          select: %{
            id: d.id,
            name: fragment("COALESCE(?, ?, ?)", google.name, entra.name, okta.name),
            type: d.type
          },
          order_by: [asc: fragment("COALESCE(?, ?, ?)", google.name, entra.name, okta.name)]
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, _} ->
            []

          directories ->
            directories
            |> Enum.map(fn %{id: id, name: name} ->
              %DirectoryOption{id: id, name: name}
            end)
        end

      # Add Firezone option at the beginning
      [%DirectoryOption{id: "firezone", name: "Firezone"} | directories]
    end

    def filter_by_directory(queryable, "firezone") do
      # Firezone directory - groups created without a directory
      {queryable, dynamic([groups: groups], is_nil(groups.directory_id))}
    end

    def filter_by_directory(queryable, directory_id) do
      # Filter for groups created by a specific directory
      {queryable, dynamic([groups: groups], groups.directory_id == ^directory_id)}
    end

    def filter_by_name(queryable, search_term) do
      {queryable, dynamic([groups: groups], fulltext_search(groups.name, ^search_term))}
    end

    def get_group!(id, subject) do
      from(g in Portal.Group, as: :groups)
      |> join(:left, [groups: g], d in Directory,
        on: d.id == g.directory_id and d.account_id == g.account_id,
        as: :directory
      )
      |> where([groups: groups], groups.id == ^id)
      |> select_merge([groups: g, directory: d], %{
        directory_type: d.type
      })
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def get_actor!(id, subject) do
      from(a in Portal.Actor, as: :actors)
      |> where([actors: a], a.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def search_actors(search_term, subject, exclude_actors) do
      exclude_ids = Enum.map(exclude_actors, & &1.id)

      case from(a in Portal.Actor, as: :actors)
           |> where(
             [actors: a],
             (fulltext_search(a.name, ^search_term) or fulltext_search(a.email, ^search_term)) and
               a.id not in ^exclude_ids
           )
           |> limit(10)
           |> Safe.scoped(subject, :replica)
           |> Safe.all() do
        actors when is_list(actors) -> actors
        {:error, _} -> []
      end
    end

    def disable_policy_for_resource(group, resource_id, subject) do
      from(p in Portal.Policy, as: :policies)
      |> where(
        [policies: p],
        p.group_id == ^group.id and p.resource_id == ^resource_id and is_nil(p.disabled_at)
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(fn policy ->
        Ecto.Changeset.change(policy, %{disabled_at: DateTime.utc_now()})
        |> Safe.scoped(subject)
        |> Safe.update()
      end)
    end

    def enable_policy_for_resource(group, resource_id, subject) do
      from(p in Portal.Policy, as: :policies)
      |> where(
        [policies: p],
        p.group_id == ^group.id and p.resource_id == ^resource_id and not is_nil(p.disabled_at)
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(fn policy ->
        Ecto.Changeset.change(policy, %{disabled_at: nil})
        |> Safe.scoped(subject)
        |> Safe.update()
      end)
    end

    def delete_policy_for_resource(group, resource_id, subject) do
      from(p in Portal.Policy, as: :policies)
      |> where([policies: p], p.group_id == ^group.id and p.resource_id == ^resource_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(&(Safe.scoped(&1, subject) |> Safe.delete()))
    end

    def list_group_members(group, subject, page, page_size, filter) do
      base =
        from(a in Portal.Actor, as: :actors)
        |> join(:inner, [actors: a], m in Portal.Membership,
          on: m.actor_id == a.id and m.group_id == ^group.id,
          as: :memberships
        )
        |> order_by([actors: a], asc: a.name)

      base =
        if filter != "" do
          search = "%#{String.downcase(filter)}%"

          where(
            base,
            [actors: a],
            ilike(a.name, ^search) or ilike(a.email, ^search)
          )
        else
          base
        end

      total =
        base
        |> exclude(:order_by)
        |> select([actors: a], count(a.id))
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> case do
          {:error, _} -> 0
          nil -> 0
          n -> n
        end

      members =
        base
        |> limit(^page_size)
        |> offset(^((page - 1) * page_size))
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, _} -> []
          list -> list
        end

      {members, total}
    end

    def remove_group_member(group, actor_id, subject) do
      from(m in Portal.Membership, as: :memberships)
      |> where([memberships: m], m.group_id == ^group.id and m.actor_id == ^actor_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(&(Safe.scoped(&1, subject) |> Safe.delete()))
    end

    def list_available_resources(existing_resource_ids, subject) do
      from(r in Portal.Resource, as: :resources)
      |> where([resources: r], r.id not in ^existing_resource_ids)
      |> order_by([resources: r], asc: r.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        resources -> resources
      end
    end

    def insert_policy(attrs, subject) do
      import Ecto.Changeset

      changeset =
        %Portal.Policy{}
        |> cast(attrs, ~w[group_id resource_id]a)
        |> validate_required(~w[group_id resource_id]a)
        |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
        |> Portal.Policy.changeset()
        |> put_change(:account_id, subject.account.id)
        |> populate_group_idp_id(subject)

      Safe.scoped(changeset, subject)
      |> Safe.insert()
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
      import Ecto.Changeset

      case get_change(changeset, :group_id) do
        nil ->
          changeset

        group_id ->
          idp_id =
            from(g in Portal.Group, where: g.id == ^group_id, select: g.idp_id)
            |> Safe.scoped(subject, :replica)
            |> Safe.one()

          put_change(changeset, :group_idp_id, idp_id)
      end
    end

    def list_resources_for_group(group, subject) do
      from(r in Portal.Resource, as: :resources)
      |> join(:inner, [resources: r], p in Portal.Policy,
        on: p.resource_id == r.id and p.group_id == ^group.id,
        as: :policies
      )
      |> select_merge([policies: p], %{
        policy_id: p.id,
        policy_disabled_at: p.disabled_at
      })
      |> order_by([policies: p, resources: r], desc: is_nil(p.disabled_at), asc: r.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        resources -> resources
      end
    end

    def get_group_with_actors!(id, subject) do
      query =
        from(g in Portal.Group, as: :groups)
        |> where([groups: groups], groups.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> select_merge([groups: g, directory: d], %{
          directory_type: d.type
        })
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> join(:left, [groups: g], m in assoc(g, :memberships), as: :memberships)
        |> join(:left, [memberships: m], a in assoc(m, :actor), as: :actors)
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?)",
                gd.name,
                ed.name,
                od.name
              )
          }
        )
        |> preload([memberships: m, actors: a], memberships: m, actors: a)

      query |> Safe.scoped(subject, :replica) |> Safe.one!(fallback_to_primary: true)
    end

    def preloads do
      []
    end

    def create(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete(group, subject) do
      group
      |> Safe.scoped(subject)
      |> Safe.delete()
    end
  end
end
