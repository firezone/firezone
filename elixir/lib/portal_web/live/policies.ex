defmodule PortalWeb.Policies do
  use PortalWeb, :live_view

  import PortalWeb.Policies.Components,
    only: [
      available_conditions: 1,
      map_condition_params: 2,
      maybe_drop_unsupported_conditions: 2,
      policy_panel: 1,
      resource_type_badge_class: 1,
      condition_short_label: 1
    ]

  alias Portal.{Changes.Change, Policy, Authentication, PubSub}
  alias __MODULE__.Database

  @tod_pending_empty %{"on" => "", "off" => "", "days" => []}
  import Ecto.Changeset
  import Portal.Changeset

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(stale: false)
      |> assign(page_title: "Policies")
      |> assign(selected_policy: nil, policy_providers: [])
      |> assign(base_policy_assigns(socket))
      |> assign_live_table("policies",
        query_module: Database,
        sortable_fields: [],
        hide_filters: [
          :group_id,
          :group_name,
          :resource_id,
          :resource_name,
          :site_id
        ],
        callback: &handle_policies_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    policy = Database.get_policy(id, socket.assigns.subject)
    providers = Database.all_active_providers(socket.assigns.account, socket.assigns.subject)

    filter_site =
      with %{"policies_filter" => %{"site_id" => site_id}} <- params do
        Database.get_site(site_id, socket.assigns.subject)
      else
        _ -> nil
      end

    filter_resource =
      with %{"policies_filter" => %{"resource_id" => resource_id}} <- params do
        Database.get_resource(resource_id, socket.assigns.subject)
      else
        _ -> nil
      end

    {:noreply,
     assign(
       socket,
       [
         filter_site: filter_site,
         filter_resource: filter_resource,
         selected_policy: policy,
         policy_providers: providers,
         return_to: uri_path(uri)
       ] ++ show_policy_assigns(socket)
     )}
  end

  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    form = new_policy(%{}, socket.assigns.subject) |> to_form()
    providers = Database.all_active_providers(socket.assigns.account, socket.assigns.subject)

    {:noreply,
     assign(
       socket,
       [
         filter_site: nil,
         filter_resource: nil,
         selected_policy: nil,
         policy_providers: providers,
         return_to: uri_path(uri)
       ] ++ new_policy_assigns(socket, form)
     )}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    policy = Database.get_policy(id, socket.assigns.subject)
    form = change_policy(policy) |> to_form()

    filter_site =
      with %{"policies_filter" => %{"site_id" => site_id}} <- params do
        Database.get_site(site_id, socket.assigns.subject)
      else
        _ -> nil
      end

    filter_resource =
      with %{"policies_filter" => %{"resource_id" => resource_id}} <- params do
        Database.get_resource(resource_id, socket.assigns.subject)
      else
        _ -> nil
      end

    {:noreply,
     assign(
       socket,
       [
         filter_site: filter_site,
         filter_resource: filter_resource,
         selected_policy: policy,
         policy_providers:
           Database.all_active_providers(socket.assigns.account, socket.assigns.subject),
         return_to: uri_path(uri)
       ] ++ edit_policy_assigns(socket, policy, form)
     )}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    filter_site =
      with %{"policies_filter" => %{"site_id" => site_id}} <- params do
        Database.get_site(site_id, socket.assigns.subject)
      else
        _ -> nil
      end

    filter_resource =
      with %{"policies_filter" => %{"resource_id" => resource_id}} <- params do
        Database.get_resource(resource_id, socket.assigns.subject)
      else
        _ -> nil
      end

    {:noreply,
     assign(
       socket,
       [
         filter_site: filter_site,
         filter_resource: filter_resource,
         selected_policy: nil,
         policy_providers: [],
         return_to: uri_path(uri)
       ] ++ default_policy_assigns(socket)
     )}
  end

  defp uri_path(uri) do
    parsed = URI.parse(uri)

    case parsed.query do
      nil -> parsed.path
      query -> "#{parsed.path}?#{query}"
    end
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, group: [:directory], resource: [])

    with {:ok, policies, metadata} <- Database.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="ri-shield-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Policies</:title>
        <:description>
          Rules that grant a group access to a resource.
        </:description>
        <:action>
          <.docs_action path="/deploy/policies" />
          <.button style="primary" icon="ri-add-line" phx-click="open_new_policy_form">
            New Policy
          </.button>
        </:action>
        <:filters>
          <% conditions_count = Enum.count(@policies, fn p -> length(p.conditions) > 0 end) %>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {@policies_metadata.count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            With conditions {conditions_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            No conditions {length(@policies) - conditions_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          stale={@stale}
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          row_click={fn policy -> ~p"/#{@account}/policies/#{policy.id}?#{@query_params}" end}
          row_selected={
            fn policy ->
              not is_nil(@selected_policy) and policy.id == @selected_policy.id
            end
          }
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
          class="flex-1 min-h-0"
        >
          <:notice :if={@filter_site} type="info">
            Viewing Policies for Site <strong>{@filter_site.name}</strong>.
            <.link navigate={~p"/#{@account}/policies"} class={link_style()}>
              View all policies
            </.link>
          </:notice>
          <:notice :if={@filter_resource} type="info">
            Viewing Policies for Resource <strong>{@filter_resource.name}</strong>.
            <.link navigate={~p"/#{@account}/policies"} class={link_style()}>
              View all policies
            </.link>
          </:notice>
          <:col :let={policy} label="Policy">
            <div class="font-medium transition-colors text-[var(--text-primary)] group-hover:text-[var(--brand)]">
              <%= if policy.group do %>
                {policy.group.name} — {policy.resource.name}
              <% else %>
                <span class="text-amber-600">(Group deleted)</span> — {policy.resource.name}
              <% end %>
            </div>
            <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">
              {policy.id}
            </div>
          </:col>
          <:col :let={policy} label="Status" class="w-32">
            <.status_badge status={if is_nil(policy.disabled_at), do: :active, else: :disabled} />
          </:col>
          <:col :let={policy} label="Group" class="w-36 lg:w-72">
            <%= if policy.group do %>
              <div class="flex items-center gap-2">
                <div class="flex items-center justify-center w-5 h-5 rounded-full bg-[var(--icon-bg)] border border-[var(--border)] shrink-0">
                  <.provider_icon type={provider_type_from_group(policy.group)} class="w-3 h-3" />
                </div>
                <.link
                  navigate={~p"/#{@account}/groups/#{policy.group}"}
                  class="text-sm text-[var(--text-secondary)] truncate hover:text-[var(--text-primary)] transition-colors"
                >
                  {policy.group.name}
                </.link>
              </div>
            <% else %>
              <span class="text-xs text-[var(--text-muted)] italic">Group deleted</span>
            <% end %>
          </:col>
          <:col :let={policy} label="Resource" class="w-36 lg:w-72">
            <div class="flex items-center gap-2">
              <span class={resource_type_badge_class(policy.resource.type)}>
                {policy.resource.type}
              </span>
              <.link
                navigate={~p"/#{@account}/resources/#{policy.resource_id}"}
                class="text-sm text-[var(--text-secondary)] truncate hover:text-[var(--text-primary)] transition-colors"
              >
                {policy.resource.name}
              </.link>
            </div>
          </:col>
          <:col :let={policy} label="Conditions" class="w-28 lg:w-72">
            <%= if length(policy.conditions) > 0 do %>
              <span class="lg:hidden text-xs text-[var(--text-secondary)]">
                {length(policy.conditions)} condition{if length(policy.conditions) != 1, do: "s"}
              </span>
              <div class="hidden lg:flex items-center gap-1.5 flex-wrap">
                <%= for condition <- policy.conditions do %>
                  <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium bg-[var(--surface-raised)] text-[var(--text-secondary)] border border-[var(--border)]">
                    {condition_short_label(condition.property)}
                  </span>
                <% end %>
              </div>
            <% else %>
              <span class="text-xs text-[var(--text-muted)]">—</span>
            <% end %>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-shield-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No policies yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Create a policy to grant actors access to resources.
                </p>
              </div>
              <.link
                patch={~p"/#{@account}/policies/new"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="ri-add-line" class="w-3 h-3" /> Add a Policy
              </.link>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.policy_panel
        account={@account}
        policy={@selected_policy}
        providers={@policy_providers}
        subject={@subject}
        panel={policy_panel_state(assigns)}
        conditions_state={policy_conditions_state(assigns)}
        confirm_state={policy_confirm_state(assigns)}
      />
    </div>
    """
  end

  defp policy_panel_state(assigns) do
    %{
      panel_view: assigns.policy_panel.view,
      panel_form: assigns.policy_panel.form,
      panel_selected_resource: assigns.policy_panel.selected_resource
    }
  end

  defp policy_conditions_state(assigns) do
    %{
      panel_timezone: assigns.policy_conditions.timezone,
      panel_active_conditions: assigns.policy_conditions.active_conditions,
      panel_conditions_dropdown_open: assigns.policy_conditions.conditions_dropdown_open?,
      panel_location_search: assigns.policy_conditions.location_search,
      panel_location_operator: assigns.policy_conditions.location_operator,
      panel_location_values: assigns.policy_conditions.location_values,
      panel_ip_range_operator: assigns.policy_conditions.ip_range_operator,
      panel_ip_range_values: assigns.policy_conditions.ip_range_values,
      panel_ip_range_input: assigns.policy_conditions.ip_range_input,
      panel_auth_provider_operator: assigns.policy_conditions.auth_provider_operator,
      panel_auth_provider_values: assigns.policy_conditions.auth_provider_values,
      panel_tod_values: assigns.policy_conditions.tod_values,
      panel_tod_adding: assigns.policy_conditions.tod_adding?,
      panel_tod_pending: assigns.policy_conditions.tod_pending,
      panel_tod_pending_error: assigns.policy_conditions.tod_pending_error
    }
  end

  defp policy_confirm_state(assigns) do
    %{
      confirm_disable_policy: assigns.policy_confirm.disable?,
      confirm_delete_policy: assigns.policy_confirm.delete?
    }
  end

  defp base_policy_assigns(socket) do
    [
      policy_panel: %{
        view: :list,
        form: nil,
        selected_resource: nil
      },
      policy_conditions: %{
        timezone: Map.get(socket.private[:connect_params] || %{}, "timezone", "UTC"),
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
        tod_pending: @tod_pending_empty,
        tod_pending_error: nil
      },
      policy_confirm: %{
        disable?: false,
        delete?: false
      }
    ]
  end

  defp default_policy_assigns(socket), do: base_policy_assigns(socket)

  defp show_policy_assigns(socket), do: base_policy_assigns(socket)

  defp new_policy_assigns(socket, form) do
    Keyword.put(base_policy_assigns(socket), :policy_panel, %{
      view: :new_form,
      form: form,
      selected_resource: nil
    })
  end

  defp edit_policy_assigns(socket, policy, form) do
    Keyword.put(base_policy_assigns(socket), :policy_panel, %{
      view: :edit_form,
      form: form,
      selected_resource: policy.resource
    }) ++ init_condition_assigns(policy, socket)
  end

  defp merge_state(socket, key, attrs) do
    update(socket, key, &Map.merge(&1, Map.new(attrs)))
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
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/policies?#{params}")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.policy_panel.view in [:new_form, :edit_form] do
    path =
      case socket.assigns.live_action do
        :edit -> ~p"/#{socket.assigns.account}/policies/#{socket.assigns.selected_policy.id}"
        _ -> ~p"/#{socket.assigns.account}/policies"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_policy) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/policies?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_disable_policy", _params, socket) do
    {:noreply, merge_state(socket, :policy_confirm, disable?: true)}
  end

  def handle_event("cancel_disable_policy", _params, socket) do
    {:noreply, merge_state(socket, :policy_confirm, disable?: false)}
  end

  def handle_event("confirm_delete_policy", _params, socket) do
    {:noreply, merge_state(socket, :policy_confirm, delete?: true)}
  end

  def handle_event("cancel_delete_policy", _params, socket) do
    {:noreply, merge_state(socket, :policy_confirm, delete?: false)}
  end

  def handle_event("disable_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    {:ok, updated} = disable_policy(policy, socket.assigns.subject)
    updated = %{updated | group: policy.group, resource: policy.resource}

    {:noreply,
     socket
     |> put_flash(:success, "Policy disabled successfully.")
     |> assign(selected_policy: updated)
     |> merge_state(:policy_confirm, disable?: false)
     |> reload_live_table!("policies")}
  end

  def handle_event("enable_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    {:ok, updated} = enable_policy(policy, socket.assigns.subject)
    updated = %{updated | group: policy.group, resource: policy.resource}

    {:noreply,
     socket
     |> put_flash(:success, "Policy enabled successfully.")
     |> assign(selected_policy: updated)
     |> reload_live_table!("policies")}
  end

  def handle_event("delete_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    {:ok, _} = delete_policy(policy, socket.assigns.subject)

    {:noreply,
     socket
     |> put_flash(:success, "Policy deleted successfully.")
     |> merge_state(:policy_confirm, delete?: false)
     |> reload_live_table!("policies")
     |> push_patch(to: ~p"/#{socket.assigns.account}/policies")}
  end

  def handle_event("open_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/policies/#{socket.assigns.selected_policy.id}/edit"
     )}
  end

  def handle_event("cancel_policy_form", _params, socket) do
    path =
      case socket.assigns.live_action do
        :edit -> ~p"/#{socket.assigns.account}/policies/#{socket.assigns.selected_policy.id}"
        _ -> ~p"/#{socket.assigns.account}/policies"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("open_new_policy_form", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/policies/new")}
  end

  def handle_event("change_policy_form", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    changeset =
      if socket.assigns.live_action == :new do
        new_policy(params, socket.assigns.subject)
      else
        change_policy(socket.assigns.selected_policy, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, merge_state(socket, :policy_panel, form: to_form(changeset))}
  end

  def handle_event("submit_policy_form", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    if socket.assigns.live_action == :new do
      case create_policy(params, socket.assigns.subject) do
        {:ok, policy} ->
          {:noreply,
           socket
           |> put_flash(:success, "Policy created successfully.")
           |> reload_live_table!("policies")
           |> push_patch(to: ~p"/#{socket.assigns.account}/policies/#{policy.id}")}

        {:error, changeset} ->
          {:noreply, merge_state(socket, :policy_panel, form: to_form(changeset))}
      end
    else
      policy = socket.assigns.selected_policy
      changeset = change_policy(policy, params)

      case Database.update_policy(changeset, socket.assigns.subject) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> put_flash(:success, "Policy updated successfully.")
           |> reload_live_table!("policies")
           |> push_patch(to: ~p"/#{socket.assigns.account}/policies/#{updated.id}")}

        {:error, changeset} ->
          {:noreply, merge_state(socket, :policy_panel, form: to_form(changeset))}
      end
    end
  end

  def handle_event("toggle_conditions_dropdown", _params, socket) do
    {:noreply,
     update(socket, :policy_conditions, fn conditions ->
       Map.update!(conditions, :conditions_dropdown_open?, &(!&1))
     end)}
  end

  def handle_event("add_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     update(socket, :policy_conditions, fn conditions ->
       conditions
       |> Map.put(:active_conditions, conditions.active_conditions ++ [type])
       |> Map.put(:conditions_dropdown_open?, false)
     end)}
  end

  def handle_event("remove_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     update(socket, :policy_conditions, fn conditions ->
       Map.put(conditions, :active_conditions, List.delete(conditions.active_conditions, type))
     end)}
  end

  def handle_event("update_location_search", %{"_location_search" => search}, socket) do
    {:noreply, merge_state(socket, :policy_conditions, location_search: search)}
  end

  def handle_event("change_location_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :policy_conditions, location_operator: op)}
  end

  def handle_event("toggle_location_value", %{"code" => code}, socket) do
    values = socket.assigns.policy_conditions.location_values

    updated = if code in values, do: List.delete(values, code), else: values ++ [code]

    {:noreply, merge_state(socket, :policy_conditions, location_values: updated)}
  end

  def handle_event("change_ip_range_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :policy_conditions, ip_range_operator: op)}
  end

  def handle_event("update_ip_range_input", %{"_ip_range_input" => value}, socket) do
    {:noreply, merge_state(socket, :policy_conditions, ip_range_input: value)}
  end

  def handle_event("add_ip_range_value", _params, socket) do
    value = String.trim(socket.assigns.policy_conditions.ip_range_input)

    if value != "" and value not in socket.assigns.policy_conditions.ip_range_values do
      {:noreply,
       merge_state(socket, :policy_conditions,
         ip_range_values: socket.assigns.policy_conditions.ip_range_values ++ [value],
         ip_range_input: ""
       )}
    else
      {:noreply, merge_state(socket, :policy_conditions, ip_range_input: "")}
    end
  end

  def handle_event("remove_ip_range_value", %{"range" => range}, socket) do
    {:noreply,
     merge_state(socket, :policy_conditions,
       ip_range_values: List.delete(socket.assigns.policy_conditions.ip_range_values, range)
     )}
  end

  def handle_event("start_add_tod_range", _params, socket) do
    {:noreply, merge_state(socket, :policy_conditions, tod_adding?: true, tod_pending: @tod_pending_empty)}
  end

  def handle_event("cancel_tod_range", _params, socket) do
    {
      :noreply,
      merge_state(socket, :policy_conditions,
        tod_adding?: false,
        tod_pending: @tod_pending_empty,
        tod_pending_error: nil
      )
    }
  end

  def handle_event("toggle_tod_pending_day", %{"day" => day}, socket) do
    {:noreply,
     update(socket, :policy_conditions, fn conditions ->
       days = conditions.tod_pending["days"]
       updated = if day in days, do: List.delete(days, day), else: days ++ [day]
       Map.put(conditions, :tod_pending, Map.put(conditions.tod_pending, "days", updated))
     end)}
  end

  def handle_event("confirm_tod_range", _params, socket) do
    pending = socket.assigns.policy_conditions.tod_pending
    on = pending["on"] || ""
    off = pending["off"] || ""
    days = pending["days"] || []

    cond do
      days == [] or on == "" or off == "" ->
        {:noreply, merge_state(socket, :policy_conditions, tod_pending_error: "Must choose day, on-time, and off-time")}

      not valid_tod_range?(on, off) ->
        {:noreply, merge_state(socket, :policy_conditions, tod_pending_error: "End time must be after start time")}

      true ->
        {:noreply,
         update(socket, :policy_conditions, fn conditions ->
           conditions
           |> Map.put(:tod_values, conditions.tod_values ++ [pending])
           |> Map.put(:tod_adding?, false)
           |> Map.put(:tod_pending, @tod_pending_empty)
           |> Map.put(:tod_pending_error, nil)
         end)}
    end
  end

  def handle_event("remove_tod_range", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     update(socket, :policy_conditions, fn conditions ->
       Map.put(conditions, :tod_values, List.delete_at(conditions.tod_values, index))
     end)}
  end

  def handle_event("change_tod_pending", params, socket) do
    {:noreply,
     update(socket, :policy_conditions, fn conditions ->
       updates =
         Map.take(params, ["_tod_on", "_tod_off"])
         |> Map.new(fn
           {"_tod_on", v} -> {"on", v}
           {"_tod_off", v} -> {"off", v}
         end)

       conditions
       |> Map.put(:tod_pending, Map.merge(conditions.tod_pending, updates))
       |> Map.put(:tod_pending_error, nil)
     end)}
  end

  def handle_event("change_auth_provider_operator", %{"operator" => op}, socket) do
    {:noreply, merge_state(socket, :policy_conditions, auth_provider_operator: op)}
  end

  def handle_event("toggle_auth_provider_value", %{"id" => id}, socket) do
    values = socket.assigns.policy_conditions.auth_provider_values

    updated = if id in values, do: List.delete(values, id), else: values ++ [id]

    {:noreply, merge_state(socket, :policy_conditions, auth_provider_values: updated)}
  end

  def handle_info(%Change{old_struct: %Portal.Policy{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info(%Change{struct: %Portal.Policy{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info({:panel_change_resource, resource}, socket) do
    available = available_conditions(resource)
    filtered = Enum.filter(socket.assigns.policy_conditions.active_conditions, &(&1 in available))

    {:noreply,
     socket
     |> merge_state(:policy_panel, selected_resource: resource)
     |> merge_state(:policy_conditions, active_conditions: filtered)}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def on_panel_resource_change({_id, _name, resource}) do
    send(self(), {:panel_change_resource, resource})
  end

  defp new_policy(attrs, %Authentication.Subject{} = subject) do
    %Policy{}
    |> cast(attrs, ~w[description group_id resource_id]a)
    |> validate_required(~w[group_id resource_id]a)
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
    |> Policy.changeset()
    |> put_change(:account_id, subject.account.id)
  end

  defp create_policy(attrs, %Authentication.Subject{} = subject) do
    attrs
    |> new_policy(subject)
    |> Database.insert_policy(subject)
  end

  defp change_policy(%Policy{} = policy, attrs \\ %{}) do
    policy
    |> cast(attrs, ~w[description group_id resource_id]a)
    |> validate_required(~w[group_id resource_id]a)
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
    |> Policy.changeset()
  end

  defp disable_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
    changeset =
      policy
      |> change()
      |> put_default_value(:disabled_at, DateTime.utc_now())

    Database.update_policy(changeset, subject)
  end

  defp enable_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
    changeset =
      policy
      |> change()
      |> put_change(:disabled_at, nil)

    Database.update_policy(changeset, subject)
  end

  defp delete_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
    Database.delete_policy(policy, subject)
  end

  defp init_condition_assigns(%{conditions: conditions}, socket) do
    find = fn prop -> Enum.find(conditions, &(&1.property == prop)) end
    loc = find.(:remote_ip_location_region)
    ip = find.(:remote_ip)
    auth = find.(:auth_provider_id)
    tod = find.(:current_utc_datetime)

    {tod_timezone, tod_values} = parse_tod_condition(tod)

    base = [
      policy_conditions: %{
        timezone: Map.get(socket.private[:connect_params] || %{}, "timezone", "UTC"),
        active_conditions: Enum.map(conditions, & &1.property),
        conditions_dropdown_open?: false,
        location_search: "",
        location_operator: cond_op(loc, "is_in"),
        location_values: cond_values(loc),
        ip_range_operator: cond_op(ip, "is_in_cidr"),
        ip_range_values: cond_values(ip),
        ip_range_input: "",
        auth_provider_operator: cond_op(auth, "is_in"),
        auth_provider_values: cond_values(auth),
        tod_values: tod_values,
        tod_adding?: false,
        tod_pending: @tod_pending_empty,
        tod_pending_error: nil
      }
    ]

    if tod_timezone,
      do: Keyword.update!(base, :policy_conditions, &Map.put(&1, :timezone, tod_timezone)),
      else: base
  end

  @spec parse_tod_condition(map() | nil) ::
          {String.t() | nil, [%{String.t() => term()}]}
  defp parse_tod_condition(nil), do: {nil, []}

  defp parse_tod_condition(%{values: values}) do
    parsed =
      Enum.flat_map(values, fn v ->
        case String.split(v, "/", parts: 3) do
          [day, ranges_str, tz] ->
            ranges_str
            |> String.split(",")
            |> Enum.map(&{day, String.trim(&1), tz})

          _ ->
            []
        end
      end)

    timezone =
      case parsed do
        [{_, _, tz} | _] -> tz
        _ -> nil
      end

    # Group entries by their time range so "M/09:00-17:00" + "T/09:00-17:00" → one range with days ["M","T"]
    ranges =
      parsed
      |> Enum.reduce(%{}, fn
        {day, "true", _tz}, acc ->
          Map.update(acc, "00:00-23:59", [day], &(&1 ++ [day]))

        {day, range_str, _tz}, acc ->
          Map.update(acc, range_str, [day], &(&1 ++ [day]))
      end)
      |> Enum.map(fn {range_str, days} ->
        case String.split(range_str, "-", parts: 2) do
          [on_time, off_time] -> %{"on" => on_time, "off" => off_time, "days" => days}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {timezone, ranges}
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

  defp cond_op(nil, default), do: default
  defp cond_op(cond, _default), do: to_string(cond.operator)

  defp cond_values(nil), do: []
  defp cond_values(cond), do: cond.values

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Policy, Site, Resource, Group}
    alias Portal.Authentication

    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_resource(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_policy(id, subject) do
      from(p in Policy, as: :policies)
      |> where([policies: p], p.id == ^id)
      |> preload(group: [:directory], resource: [])
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def insert_policy(changeset, %Authentication.Subject{} = subject) do
      changeset = populate_group_idp_id_for_insert(changeset, subject)

      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    defp populate_group_idp_id_for_insert(changeset, subject) do
      case Ecto.Changeset.get_field(changeset, :group_id) do
        nil ->
          changeset

        group_id ->
          idp_id = get_group_idp_id(group_id, subject)
          Ecto.Changeset.put_change(changeset, :group_idp_id, idp_id)
      end
    end

    def update_policy(changeset, %Authentication.Subject{} = subject) do
      changeset = populate_group_idp_id(changeset, subject)

      Safe.scoped(changeset, subject)
      |> Safe.update()
    end

    defp populate_group_idp_id(changeset, subject) do
      case Ecto.Changeset.get_change(changeset, :group_id) do
        nil ->
          changeset

        group_id ->
          idp_id = get_group_idp_id(group_id, subject)
          Ecto.Changeset.put_change(changeset, :group_idp_id, idp_id)
      end
    end

    defp get_group_idp_id(group_id, subject) do
      from(g in Group, where: g.id == ^group_id, select: g.idp_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    def fetch_group_option(id, subject) do
      group =
        from(g in Group, as: :groups)
        |> where([groups: g], g.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
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
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name: fragment("COALESCE(?, ?, ?)", gd.name, ed.name, od.name),
            directory_type: d.type
          }
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.one!(fallback_to_primary: true)

      {:ok, {group.id, group.name, group}}
    end

    def list_group_options(search_query_or_nil, subject) do
      query =
        from(g in Group, as: :groups)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
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
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name: fragment("COALESCE(?, ?, ?)", gd.name, ed.name, od.name),
            directory_type: d.type
          }
        )
        |> order_by([groups: g], asc: g.name)
        |> limit(25)

      query =
        if search_query_or_nil in ["", nil] do
          query
        else
          from(g in query, where: fulltext_search(g.name, ^search_query_or_nil))
        end

      groups = query |> Safe.scoped(subject, :replica) |> Safe.all()
      metadata = %{limit: 25, count: length(groups)}

      {:ok, grouped_select_options(groups), metadata}
    end

    defp grouped_select_options(groups) do
      groups
      |> Enum.group_by(&option_group_label/1)
      |> Enum.sort_by(fn {{idx, _label}, _} -> idx end)
      |> Enum.map(fn {{_idx, label}, grps} ->
        {label, grps |> Enum.sort_by(& &1.name) |> Enum.map(&{&1.id, &1.name, &1})}
      end)
    end

    defp option_group_label(group) do
      cond do
        not is_nil(group.idp_id) -> {9, "Synced from #{directory_display_name(group)}"}
        group.type == :managed -> {1, "Managed by Firezone"}
        true -> {2, "Manually managed"}
      end
    end

    defp directory_display_name(%{directory_name: name}) when not is_nil(name), do: name
    defp directory_display_name(_), do: "Unknown"

    def delete_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
      Safe.scoped(policy, subject)
      |> Safe.delete()
    end

    def all_active_providers(_account, subject) do
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

    def list_policies(subject, opts \\ []) do
      from(p in Policy, as: :policies)
      |> Safe.scoped(subject, :replica)
      |> Safe.list_offset(__MODULE__, opts)
    end

    # Pagination support
    def cursor_fields,
      do: [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :resource_id,
          title: "Resource",
          type: {:string, :uuid},
          fun: &filter_by_resource_id/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
          name: :group_id,
          title: "Group",
          type: {:string, :uuid},
          fun: &filter_by_group_id/2
        },
        %Portal.Repo.Filter{
          name: :group_name,
          title: "Group Name",
          type: {:string, :websearch},
          fun: &filter_by_group_name/2
        },
        %Portal.Repo.Filter{
          name: :resource_name,
          title: "Resource Name",
          type: {:string, :websearch},
          fun: &filter_by_resource_name/2
        },
        %Portal.Repo.Filter{
          name: :group_or_resource,
          title: "Group or Resource",
          type: {:string, :websearch},
          fun: &filter_by_group_or_resource/2
        },
        %Portal.Repo.Filter{
          name: :status,
          title: "Status",
          type: :string,
          values: [
            {"Active", "active"},
            {"Disabled", "disabled"}
          ],
          fun: &filter_by_status/2
        }
      ]
    end

    def filter_by_resource_id(queryable, resource_id) do
      {queryable, dynamic([policies: p], p.resource_id == ^resource_id)}
    end

    def filter_by_site_id(queryable, site_id) do
      queryable = with_joined_resource(queryable)
      {queryable, dynamic([resource: r], r.site_id == ^site_id)}
    end

    def filter_by_group_id(queryable, group_id) do
      {queryable, dynamic([policies: p], p.group_id == ^group_id)}
    end

    def filter_by_group_name(queryable, name) do
      queryable = with_joined_group(queryable)
      {queryable, dynamic([group: g], fulltext_search(g.name, ^name))}
    end

    def filter_by_resource_name(queryable, name) do
      queryable = with_joined_resource(queryable)
      {queryable, dynamic([resource: r], fulltext_search(r.name, ^name))}
    end

    def filter_by_group_or_resource(queryable, search_term) do
      queryable = queryable |> with_joined_group() |> with_joined_resource()

      {queryable,
       dynamic(
         [group: g, resource: r],
         fulltext_search(g.name, ^search_term) or
           fulltext_search(r.name, ^search_term) or
           fulltext_search(r.address, ^search_term)
       )}
    end

    def filter_by_status(queryable, "active") do
      {queryable, dynamic([policies: p], is_nil(p.disabled_at))}
    end

    def filter_by_status(queryable, "disabled") do
      {queryable, dynamic([policies: p], not is_nil(p.disabled_at))}
    end

    defp with_joined_group(queryable) do
      if has_named_binding?(queryable, :group) do
        queryable
      else
        join(queryable, :left, [policies: p], g in assoc(p, :group), as: :group)
      end
    end

    defp with_joined_resource(queryable) do
      if has_named_binding?(queryable, :resource) do
        queryable
      else
        join(queryable, :inner, [policies: p], r in assoc(p, :resource), as: :resource)
      end
    end
  end
end
