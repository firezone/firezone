defmodule PortalWeb.Groups do
  use PortalWeb, :live_view

  alias __MODULE__.Database
  import PortalWeb.Groups.Components

  @member_page_size 10

  import Ecto.Changeset

  import PortalWeb.Policies.Components,
    only: [
      map_condition_params: 2,
      maybe_drop_unsupported_conditions: 2,
      available_conditions: 1
    ]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Groups", groups_with_policies_count: 0, selected_group: nil)
      |> assign(base_group_assigns(socket))
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
  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = changeset(%Portal.Group{}, %{})
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(selected_group: nil)
     |> assign(base_group_assigns(socket))
     |> assign(
       group_panel: group_panel_state(view: :new_form),
       group_form: group_form_state(to_form(changeset))
     )}
  end

  # Edit Group Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    group = Database.get_group_with_actors!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    if editable_group?(group) do
      changeset = changeset(group, %{})

      {:noreply,
       socket
       |> assign(selected_group: group)
       |> assign(base_group_assigns(socket))
       |> assign(
         group_panel: group_panel_state(view: :edit_form),
         group_form: group_form_state(to_form(changeset))
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
      |> assign(selected_group: group)
      |> assign(base_group_assigns(socket))
      |> assign(
        group_panel:
          group_panel_state(tab: String.to_existing_atom(Map.get(params, "tab", "members"))),
        group_resources: group_resources_state(resources: resources)
      )
      |> load_panel_members()

    {:noreply, socket}
  end

  # Default handler
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(selected_group: nil)
     |> assign(base_group_assigns(socket))}
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
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/groups?#{params}")}
  end

  def handle_event("confirm_delete_group", _params, socket) do
    {:noreply, merge_state(socket, :group_panel, confirm_delete?: true)}
  end

  def handle_event("cancel_delete_group", _params, socket) do
    {:noreply, merge_state(socket, :group_panel, confirm_delete?: false)}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.group_panel.view == :edit_form do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/groups/#{socket.assigns.selected_group.id}"
     )}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.group_panel.view == :new_form do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/groups?#{params}")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_group) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/groups?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"group" => attrs}, socket) do
    group = socket.assigns.selected_group || %Portal.Group{}
    changeset = changeset(group, attrs)

    # Only search if member_search value has changed
    current_search = Map.get(attrs, "member_search", "")
    last_search = socket.assigns.group_form.last_member_search

    {member_search_results, last_member_search} =
      if current_search != last_search do
        {get_search_results(
           current_search,
           socket.assigns.selected_group,
           socket.assigns.group_form.members_to_add,
           socket.assigns.group_form.members_to_remove,
           socket.assigns.subject
         ), current_search}
      else
        {socket.assigns.group_form.member_search_results, last_search}
      end

    {:noreply,
     merge_state(socket, :group_form,
       form: to_form(changeset),
       member_search_results: member_search_results,
       last_member_search: last_member_search
     )}
  end

  def handle_event("focus_search", _params, socket) do
    member_search = get_in(socket.assigns.group_form.form.params, ["member_search"]) || ""

    search_results =
      get_search_results(
        member_search,
        socket.assigns.selected_group,
        socket.assigns.group_form.members_to_add,
        socket.assigns.group_form.members_to_remove,
        socket.assigns.subject
      )

    {:noreply, merge_state(socket, :group_form, member_search_results: search_results)}
  end

  def handle_event("add_member", %{"actor_id" => actor_id}, socket) do
    actor = Database.get_actor!(actor_id, socket.assigns.subject)

    {members_to_add, members_to_remove} =
      add_member(
        actor,
        socket.assigns.selected_group,
        socket.assigns.group_form.members_to_add,
        socket.assigns.group_form.members_to_remove
      )

    group = socket.assigns.selected_group || %Portal.Group{}
    updated_params = Map.put(socket.assigns.group_form.form.params, "member_search", "")
    changeset = changeset(group, updated_params)

    {:noreply,
     merge_state(socket, :group_form,
       members_to_add: members_to_add,
       members_to_remove: members_to_remove,
       member_search_results: nil,
       form: to_form(changeset),
       last_member_search: ""
     )}
  end

  def handle_event("remove_member", %{"actor_id" => actor_id}, socket) do
    {members_to_add, members_to_remove} =
      remove_member(
        actor_id,
        socket.assigns.selected_group,
        socket.assigns.group_form.members_to_add,
        socket.assigns.group_form.members_to_remove
      )

    {:noreply,
     merge_state(socket, :group_form,
       members_to_add: members_to_add,
       members_to_remove: members_to_remove
     )}
  end

  def handle_event("undo_member_removal", %{"actor_id" => actor_id}, socket) do
    members_to_remove =
      Enum.reject(socket.assigns.group_form.members_to_remove, &(&1.id == actor_id))

    {:noreply, merge_state(socket, :group_form, members_to_remove: members_to_remove)}
  end

  def handle_event("blur_search", _params, socket) do
    {:noreply, merge_state(socket, :group_form, member_search_results: nil)}
  end

  def handle_event("filter_show_members", %{"filter" => filter}, socket) do
    socket =
      socket
      |> merge_state(:group_panel, show_member_filter: filter, member_page: 1)
      |> load_panel_members()

    {:noreply, socket}
  end

  def handle_event("switch_group_tab", %{"tab" => tab}, socket) do
    params = Map.put(socket.assigns.query_params, "tab", tab)

    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/groups/#{socket.assigns.selected_group.id}?#{params}"
     )}
  end

  def handle_event("open_grant_resource_form", _params, socket) do
    existing_ids = Enum.map(socket.assigns.group_resources.resources, & &1.id)
    available = Database.list_available_resources(existing_ids, socket.assigns.subject)
    providers = Database.list_providers(socket.assigns.subject)

    {:noreply,
     socket
     |> merge_state(:group_resources,
       tab_view: :grant_form,
       available_resources: available,
       grant_selected_resource_ids: [],
       grant_resource_form: to_grant_resource_form(),
       grant_resource_search: ""
     )
     |> assign(grant_conditions: grant_conditions_state(socket, providers: providers))}
  end

  def handle_event("close_grant_resource_form", _params, socket) do
    {:noreply,
     socket
     |> assign(
       group_resources: group_resources_state(resources: socket.assigns.group_resources.resources)
     )
     |> assign(grant_conditions: grant_conditions_state(socket))}
  end

  def handle_event("search_grant_resources", %{"value" => search}, socket) do
    {:noreply, merge_state(socket, :group_resources, grant_resource_search: search)}
  end

  def handle_event("toggle_grant_resource", %{"resource_id" => resource_id}, socket) do
    selected = socket.assigns.group_resources.grant_selected_resource_ids

    updated =
      if resource_id in selected do
        List.delete(selected, resource_id)
      else
        if length(selected) < 5 do
          selected ++ [resource_id]
        else
          selected
        end
      end

    allowed =
      updated
      |> Enum.map(fn id ->
        Enum.find(socket.assigns.group_resources.available_resources, &(&1.id == id))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&available_conditions/1)
      |> case do
        [] -> []
        lists -> Enum.reduce(lists, &(Enum.filter(&2, fn c -> c in &1 end)))
      end

    active =
      Enum.filter(socket.assigns.grant_conditions.active_conditions, &(&1 in allowed))

    {:noreply,
     socket
     |> merge_state(:group_resources, grant_selected_resource_ids: updated)
     |> merge_state(:grant_conditions, active_conditions: active)}
  end

  def handle_event("submit_grant_resource", params, socket) do
    group = socket.assigns.selected_group
    selected_resource_ids = socket.assigns.group_resources.grant_selected_resource_ids
    policy_params = Map.get(params, "policy", %{})

    condition_attrs =
      policy_params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)
      |> Map.put("group_id", group.id)

    result =
      Enum.reduce_while(selected_resource_ids, :ok, fn resource_id, :ok ->
        attrs = Map.put(condition_attrs, "resource_id", resource_id)

        case Database.insert_policy(attrs, socket.assigns.subject) do
          {:ok, _policy} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)

    case result do
      :ok ->
        resources = Database.list_resources_for_group(group, socket.assigns.subject)

        {:noreply,
         socket
         |> assign(group_resources: group_resources_state(resources: resources))
         |> assign(grant_conditions: grant_conditions_state(socket))}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :group_resources,
           grant_resource_form: to_form(changeset, as: :policy)
         )}
    end
  end

  def handle_event("toggle_conditions_dropdown", _params, socket) do
    {:noreply,
     merge_state(socket, :grant_conditions,
       conditions_dropdown_open?: !socket.assigns.grant_conditions.conditions_dropdown_open?
     )}
  end

  def handle_event("add_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     merge_state(socket, :grant_conditions,
       active_conditions: socket.assigns.grant_conditions.active_conditions ++ [type],
       conditions_dropdown_open?: false
     )}
  end

  def handle_event("remove_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     merge_state(socket, :grant_conditions,
       active_conditions: List.delete(socket.assigns.grant_conditions.active_conditions, type)
     )}
  end

  def handle_event("update_location_search", %{"_location_search" => search}, socket) do
    {:noreply, merge_state(socket, :grant_conditions, location_search: search)}
  end

  def handle_event("change_location_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :grant_conditions, location_operator: op)}
  end

  def handle_event("toggle_location_value", %{"code" => code}, socket) do
    values = socket.assigns.grant_conditions.location_values
    updated = if code in values, do: List.delete(values, code), else: values ++ [code]
    {:noreply, merge_state(socket, :grant_conditions, location_values: updated)}
  end

  def handle_event("change_ip_range_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :grant_conditions, ip_range_operator: op)}
  end

  def handle_event("update_ip_range_input", %{"_ip_range_input" => value}, socket) do
    {:noreply, merge_state(socket, :grant_conditions, ip_range_input: value)}
  end

  def handle_event("add_ip_range_value", _params, socket) do
    value = String.trim(socket.assigns.grant_conditions.ip_range_input)

    if value != "" and value not in socket.assigns.grant_conditions.ip_range_values do
      {:noreply,
       merge_state(socket, :grant_conditions,
         ip_range_values: socket.assigns.grant_conditions.ip_range_values ++ [value],
         ip_range_input: ""
       )}
    else
      {:noreply, merge_state(socket, :grant_conditions, ip_range_input: "")}
    end
  end

  def handle_event("remove_ip_range_value", %{"value" => value}, socket) do
    {:noreply,
     merge_state(socket, :grant_conditions,
       ip_range_values: List.delete(socket.assigns.grant_conditions.ip_range_values, value)
     )}
  end

  def handle_event("change_auth_provider_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :grant_conditions, auth_provider_operator: op)}
  end

  def handle_event("toggle_auth_provider_value", %{"id" => id}, socket) do
    values = socket.assigns.grant_conditions.auth_provider_values
    updated = if id in values, do: List.delete(values, id), else: values ++ [id]
    {:noreply, merge_state(socket, :grant_conditions, auth_provider_values: updated)}
  end

  def handle_event("start_add_tod_range", _params, socket) do
    {:noreply,
     merge_state(socket, :grant_conditions,
       tod_adding?: true,
       tod_pending: %{"on" => "", "off" => "", "days" => []}
     )}
  end

  def handle_event("cancel_tod_range", _params, socket) do
    {:noreply,
     merge_state(socket, :grant_conditions,
       tod_adding?: false,
       tod_pending: %{"on" => "", "off" => "", "days" => []},
       tod_pending_error: nil
     )}
  end

  def handle_event("toggle_tod_pending_day", %{"day" => day}, socket) do
    {:noreply,
     update(socket, :grant_conditions, fn cond ->
       days = cond.tod_pending["days"]
       updated = if day in days, do: List.delete(days, day), else: days ++ [day]
       Map.put(cond, :tod_pending, Map.put(cond.tod_pending, "days", updated))
     end)}
  end

  def handle_event("confirm_tod_range", _params, socket) do
    pending = socket.assigns.grant_conditions.tod_pending
    on = pending["on"] || ""
    off = pending["off"] || ""
    days = pending["days"] || []

    cond do
      days == [] or on == "" or off == "" ->
        {:noreply, merge_state(socket, :grant_conditions, tod_pending_error: "Must choose day, on-time, and off-time")}

      not valid_tod_range?(on, off) ->
        {:noreply, merge_state(socket, :grant_conditions, tod_pending_error: "End time must be after start time")}

      true ->
        {:noreply,
         update(socket, :grant_conditions, fn cond ->
           cond
           |> Map.put(:tod_values, cond.tod_values ++ [pending])
           |> Map.put(:tod_adding?, false)
           |> Map.put(:tod_pending, %{"on" => "", "off" => "", "days" => []})
           |> Map.put(:tod_pending_error, nil)
         end)}
    end
  end

  def handle_event("remove_tod_range", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     update(socket, :grant_conditions, fn cond ->
       Map.put(cond, :tod_values, List.delete_at(cond.tod_values, index))
     end)}
  end

  def handle_event("change_tod_pending", params, socket) do
    {:noreply,
     update(socket, :grant_conditions, fn cond ->
       updates =
         Map.take(params, ["_tod_on", "_tod_off"])
         |> Map.new(fn
           {"_tod_on", v} -> {"on", v}
           {"_tod_off", v} -> {"off", v}
         end)

       cond
       |> Map.put(:tod_pending, Map.merge(cond.tod_pending, updates))
       |> Map.put(:tod_pending_error, nil)
     end)}
  end

  def handle_event("toggle_resource_access_actions", %{"resource_id" => id}, socket) do
    current = socket.assigns.group_resources.resource_access_actions_open_id

    {:noreply,
     merge_state(socket, :group_resources,
       resource_access_actions_open_id: if(current == id, do: nil, else: id)
     )}
  end

  def handle_event("close_resource_access_actions", _params, socket) do
    {:noreply, merge_state(socket, :group_resources, resource_access_actions_open_id: nil)}
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
         merge_state(socket, :group_resources,
           resources: resources,
           resource_access_actions_open_id: nil
         )}

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
         merge_state(socket, :group_resources,
           resources: resources,
           resource_access_actions_open_id: nil
         )}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_remove_resource_access", %{"resource_id" => resource_id}, socket) do
    {:noreply,
     merge_state(socket, :group_resources,
       confirm_remove_resource_access_id: resource_id,
       resource_access_actions_open_id: nil
     )}
  end

  def handle_event("cancel_remove_resource_access", _params, socket) do
    {:noreply, merge_state(socket, :group_resources, confirm_remove_resource_access_id: nil)}
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
         merge_state(socket, :group_resources,
           resources: resources,
           confirm_remove_resource_access_id: nil
         )}

      {:error, _} ->
        {:noreply, merge_state(socket, :group_resources, confirm_remove_resource_access_id: nil)}
    end
  end

  def handle_event("prev_member_page", _params, socket) do
    socket =
      socket
      |> merge_state(:group_panel,
        member_page: max(1, socket.assigns.group_panel.member_page - 1)
      )
      |> load_panel_members()

    {:noreply, socket}
  end

  def handle_event("next_member_page", _params, socket) do
    socket =
      socket
      |> merge_state(:group_panel,
        member_page:
          min(socket.assigns.group_panel.member_pages, socket.assigns.group_panel.member_page + 1)
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
    attrs = build_attrs_with_memberships_for_add(attrs, socket.assigns.group_form.members_to_add)
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
        {:noreply, merge_state(socket, :group_form, form: to_form(changeset))}
    end
  end

  def handle_event("save", %{"group" => attrs}, socket) do
    if editable_group?(socket.assigns.selected_group) do
      attrs =
        build_attrs_with_memberships(
          attrs,
          socket.assigns.selected_group,
          socket.assigns.group_form.members_to_add,
          socket.assigns.group_form.members_to_remove
        )

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
          {:noreply, merge_state(socket, :group_form, form: to_form(changeset))}
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
          <.icon name="ri-team-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Groups</:title>
        <:description>
          Collections of users.
        </:description>
        <:action>
          <.docs_action path="/deploy/groups" />
          <.button
            style="primary"
            icon="ri-add-line"
            patch={~p"/#{@account}/groups/new"}
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
                do: "bg-[var(--brand-tertiary)] text-[var(--brand)]",
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
                <.icon name="ri-team-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No groups yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  No groups have been created yet.
                </p>
              </div>
              <.link
                patch={~p"/#{@account}/groups/new"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="ri-add-line" class="w-3 h-3" /> Add a Group
              </.link>
            </div>
          </:empty>
        </.live_table>
      </div>
      <.group_panel
        account={@account}
        group={@selected_group}
        query_params={@query_params}
        flash={@flash}
        panel={@group_panel}
        form_state={@group_form}
        members_state={@group_members}
        resources_state={@group_resources}
        conditions_state={@grant_conditions}
      />
    </div>
    """
  end

  defp base_group_assigns(socket) do
    [
      group_panel: group_panel_state(),
      group_form: group_form_state(),
      group_members: group_members_state(),
      group_resources: group_resources_state(),
      grant_conditions: grant_conditions_state(socket)
    ]
  end

  defp group_panel_state(overrides \\ []) do
    Map.merge(
      %{
        view: :list,
        tab: :members,
        confirm_delete?: false,
        show_member_filter: "",
        member_page: 1,
        member_pages: 1,
        member_total: 0
      },
      Map.new(overrides)
    )
  end

  defp group_form_state(form \\ nil, overrides \\ []) do
    Map.merge(
      %{
        form: form,
        members_to_add: [],
        members_to_remove: [],
        member_search_results: nil,
        last_member_search: ""
      },
      Map.new(overrides)
    )
  end

  defp group_members_state(overrides \\ []) do
    Map.merge(%{panel_members: []}, Map.new(overrides))
  end

  defp group_resources_state(overrides \\ []) do
    Map.merge(
      %{
        resources: [],
        tab_view: :list,
        available_resources: [],
        grant_selected_resource_ids: [],
        grant_resource_form: nil,
        grant_resource_search: "",
        resource_access_actions_open_id: nil,
        confirm_remove_resource_access_id: nil
      },
      Map.new(overrides)
    )
  end

  defp grant_conditions_state(socket, overrides \\ []) do
    timezone =
      socket.private
      |> Map.get(:connect_params, %{})
      |> Map.get("timezone", "UTC")

    Map.merge(
      %{
        providers: [],
        timezone: timezone,
        active_conditions: [],
        conditions_dropdown_open?: false,
        location_search: "",
        location_operator: "is_in",
        location_values: [],
        ip_range_operator: "is_in_cidr",
        ip_range_values: [],
        ip_range_input: "",
        auth_provider_operator: "is_in",
        auth_provider_values: [],
        tod_values: [],
        tod_adding?: false,
        tod_pending: %{"on" => "", "off" => "", "days" => []},
        tod_pending_error: nil
      },
      Map.new(overrides)
    )
  end

  defp merge_state(socket, key, updates) do
    update(socket, key, &Map.merge(&1, Map.new(updates)))
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

  defp editable_group?(%{type: :managed, name: "Everyone"}), do: false
  defp editable_group?(%{idp_id: nil}), do: true
  defp editable_group?(_group), do: false

  @spec load_panel_members(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_panel_members(socket) do
    group = socket.assigns.selected_group
    subject = socket.assigns.subject
    page = socket.assigns.group_panel.member_page
    filter = socket.assigns.group_panel.show_member_filter

    {members, total} =
      Database.list_group_members(group, subject, page, @member_page_size, filter)

    socket
    |> assign(group_members: group_members_state(panel_members: members))
    |> merge_state(:group_panel,
      member_total: total,
      member_pages: max(1, ceil(total / @member_page_size))
    )
  end

  defp directory_display_name(%{directory_name: name}) when not is_nil(name), do: name
  defp directory_display_name(%{idp_id: idp_id}) when not is_nil(idp_id), do: "Unknown"
  defp directory_display_name(_), do: "Firezone"

  defp deletable_group?(%{name: "Everyone"}), do: false
  defp deletable_group?(_group), do: true

  # Utility helpers
  defp has_content?(str), do: String.trim(str) != ""

  defp uniq_by_id(list), do: Enum.uniq_by(list, & &1.id)

  # Navigation helpers
  defp close_panel(socket) do
    if return_to = handle_return_to(socket) do
      push_navigate(socket, to: return_to)
    else
      params = Map.drop(socket.assigns.query_params, ["tab"])
      push_patch(socket, to: ~p"/#{socket.assigns.account}/groups?#{params}")
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
  defp get_search_results(search_term, selected_group, members_to_add, members_to_remove, subject) do
    if has_content?(search_term) do
      group = selected_group || %Portal.Group{actors: []}
      remove_ids = MapSet.new(members_to_remove, & &1.id)

      # Exclude current members (minus those pending removal) and pending additions
      current_actors = Enum.reject(group.actors, &MapSet.member?(remove_ids, &1.id))
      exclude_actors = uniq_by_id(current_actors ++ members_to_add)

      Database.search_actors(search_term, subject, exclude_actors)
    else
      nil
    end
  end

  defp add_member(actor, selected_group, members_to_add, members_to_remove) do
    members_to_remove = Enum.reject(members_to_remove, &(&1.id == actor.id))

    members_to_add =
      if current_member?(actor, selected_group) do
        members_to_add
      else
        uniq_by_id([actor | members_to_add])
      end

    {members_to_add, members_to_remove}
  end

  defp remove_member(actor_id, selected_group, members_to_add, members_to_remove) do
    members_to_add = Enum.reject(members_to_add, &(&1.id == actor_id))

    members_to_remove =
      if actor = find_current_member(actor_id, selected_group) do
        uniq_by_id([actor | members_to_remove])
      else
        members_to_remove
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

  defp build_attrs_with_memberships(attrs, group, members_to_add, members_to_remove) do
    final_member_ids = calculate_final_member_ids(group, members_to_add, members_to_remove)

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

  defp build_attrs_with_memberships_for_add(attrs, members_to_add) do
    member_ids = Enum.map(members_to_add, & &1.id)
    memberships = Enum.map(member_ids, &%{actor_id: &1})
    Map.put(attrs, "memberships", memberships)
  end

  defp calculate_final_member_ids(group, members_to_add, members_to_remove) do
    current_ids = Enum.map(group.actors, & &1.id)
    to_add_ids = Enum.map(members_to_add, & &1.id)
    to_remove_ids = Enum.map(members_to_remove, & &1.id)

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
    alias Portal.Repo.OffsetPaginator

    def all do
      index_query()
      |> hydrate_group_query()
    end

    defp base_group_query do
      from(groups in Portal.Group, as: :groups)
    end

    defp joined_group_query(query) do
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

      query
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
    end

    defp hydrate_group_query(query) do
      query
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
    end

    defp index_query do
      base_group_query()
      |> joined_group_query()
      |> where(
        [groups: g],
        not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
      )
    end

    # Inlined from Portal.Actors.list_groups
    def list_groups(subject, opts \\ []) do
      {filter, opts} = Keyword.pop(opts, :filter, [])
      {order_by, opts} = Keyword.pop(opts, :order_by, [])
      {page_opts, _opts} = Keyword.pop(opts, :page, [])
      base_query = index_query()

      # Apply manual ordering with NULLS LAST for count field
      {query, final_order_by} =
        case order_by do
          [{:member_counts, :desc, :count}] ->
            # Apply ordering manually with NULLS LAST, don't pass to Safe.list
            updated_query =
              base_query
              |> order_by([member_counts: mc], fragment("? DESC NULLS LAST", mc.count))

            {updated_query, []}

          [{:member_counts, :asc, :count}] ->
            # Apply ordering manually with NULLS FIRST, don't pass to Safe.list
            updated_query =
              base_query
              |> order_by([member_counts: mc], fragment("? ASC NULLS FIRST", mc.count))

            {updated_query, []}

          _ ->
            # Let Safe.list handle the ordering normally
            {base_query, order_by}
        end

      with {:ok, paginator_opts} <- OffsetPaginator.init(__MODULE__, final_order_by, page_opts),
           {:ok, filtered_query} <- Filter.filter(query, __MODULE__, filter),
           count when is_integer(count) <-
             Safe.aggregate(Safe.scoped(filtered_query, subject, :replica), :count),
           group_ids <- list_group_ids(filtered_query, paginator_opts, subject),
           {group_ids, metadata} <- OffsetPaginator.metadata(group_ids, paginator_opts) do
        groups = fetch_groups_page(group_ids, subject)
        {:ok, groups, %{metadata | count: count}}
      else
        {:error, :unauthorized} = error -> error
        {:error, _reason} = error -> error
      end
    end

    defp list_group_ids(filtered_query, paginator_opts, subject) do
      filtered_query
      |> select([groups: g], g.id)
      |> OffsetPaginator.query(paginator_opts)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    defp fetch_groups_page([], _subject), do: []

    defp fetch_groups_page(group_ids, subject) do
      groups =
        index_query()
        |> hydrate_group_query()
        |> where([groups: g], g.id in ^group_ids)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      groups_by_id = Map.new(groups, &{&1.id, &1})

      Enum.map(group_ids, fn group_id ->
        Map.fetch!(groups_by_id, group_id)
      end)
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
